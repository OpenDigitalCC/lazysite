---
title: Docs
subtitle: Authoring reference for lazysite pages.
register:
  - sitemap.xml
  - llms.txt
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

Front matter fields:

`title`
: Page title. Used in the `<title>` tag and page header. Required.

`subtitle`
: Short description shown below the title. Optional.

`ttl`
: Cache TTL in seconds. The page regenerates after this interval rather than on `.md` file edit. Useful for pages with remote data. Example: `ttl: 300`

`register`
: List of registry files this page should appear in. Values match template filenames in `templates/registries/` without the `.tt` extension.

`tt_page_var`
: Page-scoped Template Toolkit variables, available in the page body and layout for this page only. Supports `url:` and `${ENV}` prefixes same as `layout.vars`.

## URL structure

Page URLs derive from file paths, always without extension:

```
public_html/index.md          ->  /
public_html/about.md          ->  /about
public_html/docs/install.md   ->  /docs/install
public_html/docs/index.md     ->  /docs/
```

Always use extensionless URLs for internal links: `/about` not `/about.html`.

## Headings

`# H1` is reserved — the page title is rendered by the layout template. Start content headings at `##`.

## Fenced divs

Wrap content in a named CSS class:

```
::: classname
Content here. Standard Markdown works inside.
:::
```

Produces `<div class="classname">...</div>`. Class names must contain only word characters and hyphens.

Classes available in the default layout:

`widebox`
: Full-width coloured band. Use for important statements or highlights.

`textbox`
: 60% width highlighted box. Use for brief key points.

`marginbox`
: Pull quote in the margin. Use for short quotes or asides.

`examplebox`
: Evidence or example highlight. Use for concrete cases.

## Remote pages

A `.url` file contains a single URL. The processor fetches the Markdown from that URL, processes it through the full pipeline, and caches the result.

```
# File: docs/install.url
https://raw.githubusercontent.com/example/repo/main/docs/INSTALL.md
```

The remote file should include YAML front matter. Cache TTL defaults to one hour. Delete the `.html` cache file to force immediate refresh.

This is how the pages on this site are served — the content lives in the [lazysite GitHub repository][github] and the site holds only `.url` files pointing to the raw Markdown.

## Template Toolkit in pages

TT variables are expanded in page content before Markdown conversion:

```markdown
Current version: [% version %]

[% IF beta %]
::: textbox
This feature is in beta.
:::
[% END %]
```

Variables are defined in `layout.vars` (site-wide) or `tt_page_var` front matter (page-scoped).

## oEmbed

Embed video and audio with a single line:

```
::: oembed
https://www.youtube.com/watch?v=abc123
:::
```

Works with YouTube, Vimeo, SoundCloud, PeerTube, and any oEmbed provider. The embed is baked into the cached page.

## Cache management

Edit a `.md` file, then delete the corresponding `.html` to force regeneration:

```bash
# Regenerate one page
rm public_html/about.html

# Regenerate all pages (e.g. after a template change)
find public_html -name "*.html" -delete
```

Pages with `ttl:` front matter regenerate automatically after the TTL expires.

## Static site generation

Pre-render all pages for static hosting:

```bash
# Build in-place
bash build-static.sh https://example.com

# Build to a separate output directory
bash build-static.sh https://example.com ./dist
```

Deploy the output to GitHub Pages, Netlify, Cloudflare Pages, or any plain web server.

## Site-wide variables

`layout.vars` defines variables available in the layout template and all page bodies:

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
version: url:https://raw.githubusercontent.com/example/repo/main/VERSION
```

Three value types: literal strings, Apache environment variables (`${VAR}`), and remote URL fetches (`url:https://...`).

Allowlisted environment variables: `SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`, `DOCUMENT_ROOT`, `SERVER_ADMIN`.

## Installation

```bash
sudo bash install.sh
```

Registers a HestiaCP web template. Apply it to a domain, rebuild vhosts, and the processor and starter files are installed. A standalone Apache configuration is also produced.

```bash
sudo bash uninstall.sh
```

Removes Hestia template files only. Deployed domain files are not touched.

[github]: https://github.com/OpenDigitalCC/lazysite
