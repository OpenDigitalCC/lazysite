# lazysite AI Briefing

This document describes the lazysite system for an AI assistant helping to
create or maintain a site. Read it before generating any content or templates.

---

## System overview

lazysite is a Markdown-driven static site system running on Apache. Pages
are written as `.md` files with YAML front matter. A CGI processor converts
them to HTML on first request and caches the result. Subsequent requests
serve the cached file directly.

The site has two layers:

Layout
: `lazysite/templates/layout.tt` - a Template Toolkit file that wraps every page.
  Contains the full HTML structure: `<head>`, navigation, header, footer.
  Written once by a designer. Receives variables from the processor.

Content
: `.md` files in the docroot. Written by authors. Converted to HTML and
  inserted into the layout at `[% content %]`.

---

## Layout template (`lazysite/templates/layout.tt`)

### Variables available in every page render

```
[% page_title %]       Title from page front matter
[% page_subtitle %]    Subtitle from page front matter (may be empty)
[% content %]          Converted page body HTML - output unescaped
```

Plus all site-wide variables defined in `lazysite/lazysite.conf`.

### Conditional

```
[% IF page_subtitle %]
<p class="subtitle">[% page_subtitle %]</p>
[% END %]
```

### Loop

```
[% FOREACH item IN items %]
<li><a href="[% item.url %]">[% item.label %]</a></li>
[% END %]
```

### Include

```
[% INCLUDE templates/partials/nav.tt %]
```

### Minimal working template

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[% page_title %][% IF site_name %] — [% site_name %][% END %]</title>
    <link rel="stylesheet" href="/assets/css/main.css">
</head>
<body>
<header>
    <a href="/">[% site_name %]</a>
</header>
<main>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]<p class="subtitle">[% page_subtitle %]</p>[% END %]
    [% content %]
</main>
<footer>
    <p>&copy; [% year %] [% site_name %]</p>
</footer>
</body>
</html>
```

---

## Site-wide variables (`lazysite/lazysite.conf`)

One variable per line. Three value types:

### Standard variables

These two variables are used on almost every site and should always be
defined in `lazysite.conf`:

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
```

`site_url` is built from Apache CGI environment variables that are set
automatically on every request. It produces the correct scheme and hostname
for the live server. For static builds, `build-static.sh` sets these from
the URL argument passed to it.

Do not hardcode the domain in `site_url` - use the environment variable
form so the same `lazysite.conf` works on staging and production.

### All value types

```yaml
# Literal string
site_name: My Site

# Environment variable (Apache CGI - allowlisted vars only)
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

# Remote URL fetch (trimmed, cached with page TTL)
version: url:https://raw.githubusercontent.com/example/repo/main/VERSION
```

Allowlisted environment variables: `SERVER_NAME`, `REQUEST_SCHEME`,
`SERVER_PORT`, `HTTPS`, `DOCUMENT_ROOT`, `SERVER_ADMIN`.

Lines beginning with `#` are comments.

Variables are available in `layout.tt` and in page body content via
`[% variable_name %]`.

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

### Required front matter keys

`title`
: Page title. Used in `<title>` tag and page header. Required.

### Optional front matter keys

`subtitle`
: Short description shown below the title.

`ttl`
: Cache TTL in seconds. When set, the page regenerates after this many
  seconds rather than on `.md` file edit. Useful for pages with remote data.
  Example: `ttl: 300`

`register`
: List of registry files this page should appear in. Values must match
  template filenames in `lazysite/templates/registries/` without `.tt` extension.

`tt_page_var`
: Page-scoped Template Toolkit variables. Available in page body and layout
  for this page only. Supports `url:` and `${ENV}` prefixes same as
  `lazysite.conf`.

```yaml
tt_page_var:
  release_url: url:https://api.github.com/repos/example/repo/releases/latest
  beta: true
```

---

## Markdown elements

### Headings

```markdown
## Section heading
### Subsection
#### Sub-subsection
```

`# H1` is reserved - the page title is rendered by the layout template.
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

Always use extensionless URLs for internal links: `/about` not `/about.html`.

### Images

```markdown
![Alt text](/assets/img/image.png)
```

Images should be placed in `/assets/img/`.

### Lists

```markdown
- Unordered item
- Another item
  - Nested item

1. Numbered item
2. Second item
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

Language identifier is used for syntax highlighting class. Common values:
`bash`, `python`, `perl`, `javascript`, `yaml`, `json`, `html`, `css`,
`markdown`, `text`.

### Fenced divs

Wrap content in a named CSS class:

```
::: classname
Content here. Standard Markdown works inside.
:::
```

Produces `<div class="classname">...</div>`. Class name must contain only
word characters and hyphens. The CSS for these classes is in the site
stylesheet.

Common classes used on this site (confirm with site designer):

- `widebox` - full-width coloured band
- `textbox` - 60% width highlighted box
- `marginbox` - margin pull quote
- `examplebox` - evidence or example highlight

### Embedded media (oEmbed)

```
::: oembed
https://www.youtube.com/watch?v=abc123
:::
```

Works with YouTube, Vimeo, SoundCloud, PeerTube, and any oEmbed provider.
The embed is baked into the cached page - no client-side API call.

### Template Toolkit in page content

TT variables are expanded in page content before Markdown conversion:

```markdown
Current version: [% version %]

[% IF beta %]
::: textbox
This feature is in beta.
:::
[% END %]
```

---

## URL structure

Page URLs are derived from file paths, always without extension:

```
public_html/index.md              -> /
public_html/about.md              -> /about
public_html/docs/install.md       -> /docs/install
public_html/docs/index.md         -> /docs/
```

Directory index pages use `index.md` inside the directory folder.

---

## Remote pages (`.url` files)

A `.url` file contains a single URL. The processor fetches the Markdown from
that URL, processes it through the full pipeline, and caches the result.

```
# File: docs/install.url
https://raw.githubusercontent.com/example/repo/main/docs/INSTALL.md
```

The remote Markdown file should include YAML front matter. Cache TTL is
one hour by default. Delete the `.html` cache file to force immediate refresh.

---

## File locations

```
public_html/
  lazysite/
    lazysite.conf       <- site configuration (operator edits this)
    templates/
      layout.tt         <- site template (designer edits this)
      registries/
        llms.txt.tt     <- llms.txt template
        sitemap.xml.tt  <- sitemap template
    themes/             <- theme assets
  assets/
    css/                <- stylesheets
    img/                <- images
    js/                 <- scripts
  cgi-bin/
    lazysite-processor.pl <- processor (do not edit)
  404.md                <- not-found page
  index.md              <- home page
  about.md              <- content pages
  docs/
    index.md            <- docs index
    install.md          <- docs pages
```

---

## Cache management

Edit `.md` file → delete `.html` cache → page regenerates on next request.

```bash
# Regenerate one page
rm public_html/about.html

# Regenerate all pages (e.g. after template change)
find public_html -name "*.html" -delete
```

Pages with `ttl:` front matter regenerate automatically after the TTL
expires without manual cache deletion.

---

## Tasks for the AI assistant

### Creating a layout template

Ask the user:
- Site name and tagline
- Navigation links (label and URL pairs)
- Colour scheme or CSS framework preference
- Header and footer content
- Any special page sections (hero, sidebar, etc.)

Produce a complete `layout.tt` file. Reference `[% page_title %]`,
`[% page_subtitle %]`, `[% content %]`, and any site-wide variables
defined in `lazysite.conf`. Use `[% IF x %]...[% END %]` for optional elements.

### Creating a page

Ask the user:
- Page title and subtitle
- URL (determines filename and location)
- Page content - section headings, body text, lists, code blocks
- Whether the page should appear in llms.txt and sitemap.xml
- Any page-specific variables needed

Produce a `.md` file with correct YAML front matter and Markdown content.
Start headings at `##`. Use fenced divs for styled callouts. Use
extensionless internal links.

### Creating lazysite.conf

Always include `site_name` and `site_url` as the first two entries.
`site_url` must always use the environment variable form - never hardcode
the domain:

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
```

Then ask the user:
- Any remote values needed (version numbers, API data)
- Any static values needed site-wide (support email, GitHub URL, etc.)

Produce a `lazysite.conf` file. One variable per line. Add comments for
clarity.
