# lazysite Content Authoring Briefing

This document covers how to create and format content for a lazysite site.
It is written for content authors and for AI assistants helping with content
work.

For site configuration, views, and navigation, see
[configuration.md](/docs/configuration).
For developer and operator topics, see [development.md](/docs/development).
For raw mode, API mode, and query strings, see [api.md](/docs/api).

---

## How lazysite works

lazysite is a Markdown-driven static site system running on Apache. Pages
are written as `.md` files with YAML front matter. A CGI processor converts
them to HTML on first request and caches the result. Subsequent requests
serve the cached file directly.

Two layers:

View template
: `lazysite/templates/view.tt` - controls the site design and wraps every
  page. Written by a designer. Receives content from the processor.

Content
: `.md` files in the docroot. Written by authors. Converted to HTML and
  inserted into the view template at `[% content %]`.

Authors only need to work with `.md` files. The view template is a separate
concern.

---

## Page format

Every `.md` file begins with a YAML front matter block:

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

### Front matter reference

`title`
: Page title. Used in the `<title>` tag and page `<h1>`. Required.

`subtitle`
: Short description shown below the title. Optional.

`ttl`
: Cache TTL in seconds. The page regenerates after this interval rather
  than on `.md` file edit. Useful for pages pulling remote data.
  Example: `ttl: 300`

`register`
: List of registry files this page appears in. Values match template
  filenames in `lazysite/templates/registries/` without `.tt` extension.
  Common values: `llms.txt`, `sitemap.xml`, `feed.rss`, `feed.atom`.

`date`
: Publication date in `YYYY-MM-DD` format. Used in RSS/Atom feeds.
  Falls back to file mtime if not set. Example: `date: 2026-03-20`

`tt_page_var`
: Page-scoped Template Toolkit variables. Available in this page's body
  and in the view template for this page only. Supports `url:` and
  `${ENV}` prefixes same as `lazysite.conf`.

  ```yaml
  tt_page_var:
    download_base: https://github.com/example/repo/releases
    beta: true
  ```

`layout`
: Named view template for this page. Overrides the site-wide view.
  Example: `layout: minimal`

`query_params`
: URL query parameters this page accepts. Declared parameters are
  available as `[% query.param %]` in TT. Requests with matching params
  bypass the cache. Undeclared params are ignored.

  ```yaml
  query_params:
    - q
    - page
  ```

`raw`
: Set `raw: true` to output content without the view template wrapper.
  See [api.md](/docs/api).

`content_type`
: HTTP Content-Type header. Used with `raw: true` or `api: true`.
  See [api.md](/docs/api).

---

## URL structure

Page URLs derive from file paths, always without extension:

```
public_html/index.md          ->  /
public_html/about.md          ->  /about
public_html/docs/install.md   ->  /docs/install
public_html/docs/index.md     ->  /docs/
```

Always use extensionless URLs for internal links: `/about` not
`/about.html`. Directory index pages use `index.md` inside the directory.

---

## Markdown elements

### Headings

```markdown
## Section heading
### Subsection
#### Sub-subsection
```

`# H1` is reserved - the page title is rendered by the view template.
Start content headings at `##`.

### Text

```markdown
Normal paragraph text.

**Bold** and *italic* inline.

> Blockquote

`inline code`
```

### Links

```markdown
[Link text](/page-url)
[External link](https://example.com)
```

Always use extensionless URLs for internal links. TT variables in Markdown
link URLs do not resolve reliably - the Markdown parser processes URLs
before TT runs. Use an HTML `<a>` tag when the href contains a TT variable:

```html
<a href="[% download_base %]/release-[% version %].tar.gz">Download</a>
```

### Images

```markdown
![Alt text](/assets/img/image.png)
```

### Lists

```markdown
- Unordered item
- Another item
  - Nested item

1. Numbered item
2. Second item
```

### Definition lists

```markdown
Term
: Definition text here.

Another term
: Another definition.
```

### Tables

```markdown
| Column | Column | Column |
| ------ | ------ | ------ |
| Cell   | Cell   | Cell   |
```

### Code blocks

````markdown
```bash
command --option value
```

```python
def example():
    pass
```
````

Language identifier sets the syntax highlighting class. Common values:
`bash`, `python`, `perl`, `javascript`, `yaml`, `json`, `html`, `css`,
`markdown`, `text`.

Inline code and fenced code blocks are protected from Template Toolkit
processing - `[% tags %]` inside code appear literally. This is correct
behaviour for documentation pages showing code examples.

---

## Fenced divs

Wrap content in a named CSS class:

```
::: classname
Content here. Standard Markdown works inside.
:::
```

Produces `<div class="classname">...</div>`. Class names must contain only
word characters and hyphens. The CSS for these classes is in the site
stylesheet.

Common classes (confirm availability with your site designer):

`widebox`
: Full-width coloured band. Use for important statements or highlights.

`textbox`
: 60% width highlighted box. Use for brief key points alongside prose.

`marginbox`
: Pull quote in the margin. Use for short quotes or asides.

`examplebox`
: Evidence or example highlight. Use for concrete cases or evidence.

---

## Template Toolkit in pages

TT variables expand in page content before Markdown conversion. All site
variables from `lazysite.conf` and page variables from `tt_page_var` are
available.

```markdown
Current version: [% version %]

[% IF beta %]
::: textbox
This feature is in beta.
:::
[% END %]
```

### Available TT variables

Automatic variables (always set):

- `[% page_title %]` - from front matter `title`
- `[% page_subtitle %]` - from front matter `subtitle`
- `[% page_modified %]` - human-readable file mtime, e.g. "3 April 2026"
- `[% page_modified_iso %]` - ISO 8601 mtime, e.g. "2026-04-03"
- `[% query.param %]` - URL query string value (declared params only)

Plus all variables from `lazysite.conf` (site-wide) and `tt_page_var`
(page-scoped).

### TT string concatenation

Build strings from variables using the `_` operator:

```
[% filename = "release-" _ version _ ".tar.gz" %]
[% full_url = download_base _ "/" _ filename %]

<a href="[% full_url %]">[% filename %]</a>
```

Assign variables on their own line - they produce no output.

### TT conditionals

```
[% IF version %]
Version [% version %] is available.
[% ELSE %]
No version information.
[% END %]
```

### Notes on TT in pages

- TT processes the content body first, then the view template. Variables
  set in the page body (like `[% SET x = 1 %]`) are not available in
  the view template.
- TT variables in Markdown link URLs do not resolve - use HTML `<a>` tags.
- For `<dt>` elements in definition lists, Markdown link syntax with TT
  variables is supported after TT resolution.

---

## Remote pages

A `.url` file contains a single URL. The processor fetches the Markdown,
processes it through the full pipeline, and caches the result:

```
# File: docs/install.url
https://raw.githubusercontent.com/example/repo/main/docs/INSTALL.md
```

The remote file should include YAML front matter. Cache TTL defaults to
one hour. Delete the `.html` cache file to force immediate refresh.

This allows documentation to live with the code while appearing on the
site - always showing the current version.

---

## Content includes

Inline local or remote content directly into a page:

```
::: include
partials/shared-note.md
:::

::: include
https://raw.githubusercontent.com/owner/repo/main/CHANGELOG.md
:::

::: include
partials/example-config.yml
:::
```

### Path resolution

- Starts with `/` - absolute from docroot
- Starts with `http://` or `https://` - remote URL fetch
- Otherwise - relative to the current `.md` file's directory

### Content handling by type

`.md` files
: Front matter stripped, body rendered as Markdown inline. The included
  file's `title` and `layout` are ignored - only the body is used.

Code files (`.sh`, `.pl`, `.py`, `.yml`, `.json` etc.)
: Wrapped in a fenced code block with the appropriate language identifier.

`.html` files
: Inserted bare - assumed to be a valid HTML fragment.

Unknown extensions
: Wrapped in `<pre>` with HTML entities escaped.

### Error handling

Failed includes render as a silent `<span class="include-error">` tag.
A warning is written to the error log. Includes are single-pass only -
`:::include` inside an included `.md` file is not processed.

---

## oEmbed

Embed video and audio with a single line:

```
::: oembed
https://www.youtube.com/watch?v=abc123
:::

::: oembed
https://peertube.example.com/videos/watch/abc123
:::
```

Works with YouTube, Vimeo, SoundCloud, PeerTube, and any oEmbed provider.
The embed is baked into the cached page - no client-side API calls. If the
fetch fails, the block renders as a plain link with class `oembed--failed`.

---

## Registries

Pages declare which registry files they appear in via `register:` front
matter. Registries are generated files derived from page metadata.

```yaml
register:
  - sitemap.xml
  - llms.txt
  - feed.rss
  - feed.atom
```

For RSS and Atom feeds, include a `date:` front matter key:

```yaml
date: 2026-03-20
register:
  - feed.rss
  - feed.atom
```

Registries regenerate after their TTL expires (default 4 hours). To force
immediate regeneration, delete the output file:

```bash
rm public_html/llms.txt
```

---

## The 404 page

`public_html/404.md` is the not-found page. Write it like any other page:

```markdown
---
title: Page Not Found
subtitle: The page you requested could not be found
---

The page you were looking for does not exist.
Return to the [home page](/).
```

Delete `404.html` to regenerate it after edits.

---

## Cache management

Local `.md` pages regenerate automatically when the `.md` file is newer
than the cached `.html`. Editing and saving is sufficient.

Index pages (`index.md`) are served directly by the web server and bypass
the processor when cached. After editing `index.md`, delete the cache:

```bash
rm public_html/index.html
```

For all other pages, deleting the cache is only needed when the view
template changes. After editing a `.md` file, the page regenerates on the
next request automatically.

---

## Tasks for AI assistants

### Creating a page

Ask:
- Page title and subtitle
- URL path (determines filename and location)
- Page content - sections, body text, lists, code blocks
- Whether the page should appear in llms.txt, sitemap.xml, or feeds
- Any page-specific TT variables needed

Produce a `.md` file with correct YAML front matter and Markdown content.
Start headings at `##`. Use fenced divs for styled callouts. Use
extensionless internal links.

### Creating lazysite.conf

Always include `site_name` and `site_url` as the first two entries.
`site_url` must always use the environment variable form:

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
```

Ask:
- Any remote values needed (version numbers, API data)
- Any static values needed site-wide (support email, GitHub URL)

Produce a `lazysite.conf` file with one variable per line and comments
for clarity.

### Creating nav.conf

Ask for the site pages and their structure. Produce a `nav.conf` using
the format:

```
Label | /url
Parent label
  Child label | /child-url
```

Top-level items use `Label | /url`. Non-clickable group headings use
`Label` with no pipe. Children are indented with any whitespace.
One level of nesting only. Lines starting with `#` are comments.

For configuration, view creation, and operator tasks, refer to
[configuration.md](/docs/configuration) and the
[lazysite-views creating-views.md][views-doc].

[views-doc]: https://github.com/OpenDigitalCC/lazysite-views/blob/main/docs/creating-views.md
