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

`raw`
: Set `raw: true` to output the converted content body without the layout wrapper. TT variables still resolve. Useful for content fragments, AJAX partials, or API-style endpoints.

`content_type`
: Used with `raw: true` to set the HTTP `Content-type` header. Defaults to `text/html; charset=utf-8`. Example: `content_type: application/json; charset=utf-8`

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

Three value types: literal strings, CGI environment variables (`${VAR}`), and remote URL fetches (`url:https://...`).

Allowlisted environment variables: `SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`, `DOCUMENT_ROOT`, `SERVER_ADMIN`, `REDIRECT_URL`.

`${REDIRECT_URL}` contains the requested page path (e.g. `/about`) and is useful for highlighting the active navigation item in `layout.tt`.

## Advanced Template Toolkit

TT is processed in two passes — first in the page body, then in `layout.tt`. Simple variable substitution and conditionals work in both. A `url:` variable that returns JSON can be decoded and looped over, with the result baked into the cached page at render time:

```
[% USE JSON( pretty => 0 ) %]
[% releases = JSON.deserialize(releases_json) %]
[% FOREACH item IN releases %]
<a href="[% item.url %]">[% item.name %]</a>
[% END %]
```

TT variables in Markdown link URLs do not resolve reliably — the Markdown parser processes the URL before TT runs. Use HTML `<a>` tags when the href contains a TT variable:

```html
<a href="[% download_base %]/release-[% version %].tar.gz">Download</a>
```

Inline code and fenced code blocks are protected from TT processing — `[% tags %]` inside code appear literally, which is correct for documentation pages.

## Migrating from other tools

Pico CMS
: Content migrates directly. Copy your Pico `content/` files to the docroot and rename `Title:` to `title:` and `Description:` to `subtitle:` in front matter. Replace Pico theme templates with a `layout.tt` file. A one-liner to convert front matter keys across all files: `find public_html -name "*.md" | xargs sed -i 's/^Title:/title:/;s/^Description:/subtitle:/'`

Hugo
: Content files require no changes — Hugo and lazysite use the same front matter format. What needs replacing is the template system: `layout.tt` replaces your Hugo `baseof.html` or equivalent base template.

## Live demo

The [feature test page](/demo) exercises every processor capability — site variables, page variables, TT conditionals, fenced divs, code block protection, oEmbed, and more. Each section shows what to expect. A passing test shows the resolved value; a failing test shows a literal `[% tag %]`.

The demo page is itself served via a `.url` file from the lazysite repository, so it also demonstrates that mechanism in production.

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
