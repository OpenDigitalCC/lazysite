---
title: Authoring
subtitle: Writing and managing pages in lazysite.
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
: Cache TTL in seconds. The page regenerates after this interval rather than on `.md` file edit. Useful for pages that pull remote data. Example: `ttl: 300`

`register`
: List of registry files this page should appear in. Values match template filenames in `lazysite/templates/registries/` without the `.tt` extension.

`tt_page_var`
: Page-scoped Template Toolkit variables, available in the page body and layout for this page only. Supports `url:` and `${ENV}` prefixes same as `lazysite.conf`. Page variables override site variables of the same name.

`raw`
: Set `raw: true` to output the converted content body without the layout wrapper. TT variables still resolve. Useful for content fragments, AJAX partials, or API-style endpoints.

`content_type`
: Used with `raw: true` to set the HTTP `Content-type` header. Defaults to `text/html; charset=utf-8`. Example: `content_type: application/json; charset=utf-8`

`date`
: Publication date in `YYYY-MM-DD` format. Used in RSS/Atom feed entries. Falls back to file mtime if not set. Example: `date: 2026-03-20`

`layout`
: Named layout template for this page. The processor checks `lazysite/themes/NAME/view.tt` first, then `lazysite/templates/NAME.tt`, and falls back to the default `view.tt` if neither exists. Example: `layout: minimal`

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

`# H1` is reserved  -  the page title is rendered by the layout template. Start content headings at `##`.

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

The remote file should include YAML front matter. Cache TTL defaults to one hour (`$REMOTE_TTL` in `lazysite-processor.pl`). If a remote fetch fails, the stale cache is served if available. Delete the `.html` cache file to force immediate refresh.

This is how the pages on this site are served  -  the content lives in the [lazysite GitHub repository][github] and the site holds only `.url` files pointing to the raw Markdown.

## Template Toolkit in pages

TT variables are expanded in page content before Markdown conversion. Variables are processed in two passes  -  first in the page body, then in `view.tt`:

```markdown
Current version: [% version %]

[% IF beta %]
::: textbox
This feature is in beta.
:::
[% END %]
```

Variable precedence: site vars → page vars → `page_title`, `page_subtitle`, `content`.

### Automatic page variables

These variables are set automatically by the processor and available in every page render:

- `[% page_title %]`  -  from front matter `title`
- `[% page_subtitle %]`  -  from front matter `subtitle`
- `[% page_modified %]`  -  human-readable file modification date, e.g. "3 April 2026"
- `[% page_modified_iso %]`  -  ISO 8601 file modification date, e.g. "2026-04-03"

`page_modified_iso` is useful for `<time>` elements:

```html
<time datetime="[% page_modified_iso %]">[% page_modified %]</time>
```

Variables are defined in `lazysite.conf` (site-wide) or `tt_page_var` front matter (page-scoped).

## Site-wide variables

`lazysite.conf` defines variables available in the layout template and all page bodies:

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
version: url:https://raw.githubusercontent.com/example/repo/main/VERSION
```

Three value types:

Literal string
: `key: value`  -  used as-is.

Environment variable
: `key: ${ENV_VAR}`  -  interpolated from the CGI environment. Multiple vars and mixed text are supported: `${REQUEST_SCHEME}://${SERVER_NAME}`

Remote URL
: `key: url:https://...`  -  fetched, trimmed, and cached with the page TTL. Env var interpolation works inside `url:` values too.

Useful CGI environment variables: `${SERVER_NAME}`, `${REQUEST_SCHEME}`, `${SERVER_PORT}`, `${HTTPS}`, `${REDIRECT_URL}`.

`${REDIRECT_URL}` contains the requested page path (e.g. `/about`) and is useful for highlighting the active navigation item in `view.tt`.

## Advanced Template Toolkit

A `url:` variable that returns JSON can be decoded and looped over, with the result baked into the cached page at render time:

```
[% USE JSON( pretty => 0 ) %]
[% releases = JSON.deserialize(releases_json) %]
[% FOREACH item IN releases %]
<a href="[% item.url %]">[% item.name %]</a>
[% END %]
```

The `USE JSON` directive and variable assignments made in the page body are local to that pass and not available in `view.tt`. For data needed in both, set it as a site-wide variable in `lazysite.conf`.

TT variables in Markdown link URLs do not resolve reliably  -  the Markdown parser processes the URL before TT runs. Use HTML `<a>` tags when the href contains a TT variable:

```html
<a href="[% download_base %]/release-[% version %].tar.gz">Download</a>
```

For `<dt>` elements in definition lists, Markdown link syntax is supported after TT resolution:

```markdown
[release-[% version %].tar.gz]([% download_base %]/release-[% version %].tar.gz)
: Source tarball.
```

Inline code and fenced code blocks are protected from TT processing  -  `[% tags %]` inside code appear literally.

Full Template Toolkit documentation at [https://template-toolkit.org/docs/][tt2docs].

## oEmbed

Embed video and audio with a single line:

```
::: oembed
https://www.youtube.com/watch?v=abc123
:::
```

Works with YouTube, Vimeo, SoundCloud, PeerTube, and any oEmbed provider. The embed is baked into the cached page  -  no client-side API calls. If the fetch fails, the block renders as a plain link fallback with class `oembed--failed` for CSS targeting.

## Content includes

Include local or remote content inline in a page using `:::include`:

```
::: include
partials/note.md
:::
```

```
::: include
https://raw.githubusercontent.com/owner/repo/main/CHANGELOG.md
:::
```

```
::: include
partials/example.sh
:::
```

### Path resolution

- Starts with `/`  -  absolute from the docroot
- Starts with `http://` or `https://`  -  remote URL, fetched via HTTP
- Otherwise  -  relative to the directory containing the current `.md` file

### Content handling by type

`.md` files
: YAML front matter is stripped. The body is rendered through the full Markdown pipeline (fenced divs, code blocks, oEmbed) and inserted as HTML inline. The included file's `title` and `layout` are ignored  -  only the body is used.

Code files (`.sh`, `.pl`, `.py`, `.yml`, `.js`, `.json`, `.css`, `.xml`, `.toml`, `.conf`, `.cfg`, `.txt`)
: Wrapped in a fenced code block with the appropriate language identifier. For example, a `.sh` file produces `<pre><code class="language-bash">`.

`.html` / `.htm` files
: Inserted bare  -  assumed to be a valid HTML fragment.

Unknown extensions or no extension
: Wrapped in `<pre>` with HTML entities escaped.

### Error handling

If a local file is missing or a remote fetch fails, the block renders as an invisible `<span class="include-error" data-src="..."></span>` tag and a warning is written to the error log. Expose errors during development with CSS:

```css
.include-error::before { content: "include failed: " attr(data-src); color: red; }
```

### No recursive includes

`:::include` inside an included `.md` file is not processed. Includes are single-pass only  -  this prevents infinite loops and keeps behaviour predictable.

## Registries

Pages declare which registry files they appear in via the `register` front matter key. Supported registries out of the box are `llms.txt` and `sitemap.xml`. Each name maps to a Template Toolkit template in `lazysite/templates/registries/`:

```
lazysite/templates/registries/llms.txt.tt    -> public_html/llms.txt
lazysite/templates/registries/sitemap.xml.tt -> public_html/sitemap.xml
```

Registries regenerate after the registry TTL expires (default 4 hours). To force immediate regeneration, delete the output file:

```bash
rm public_html/llms.txt
```

Adding a new registry format requires only dropping a `.tt` file in `lazysite/templates/registries/`  -  no code changes needed.

### RSS and Atom feeds

Pages can register with `feed.rss` and `feed.atom` to appear in syndication feeds:

```yaml
---
title: New Feature Announcement
date: 2026-03-20
register:
  - feed.rss
  - feed.atom
  - sitemap.xml
---
```

The `date` front matter key is used as the publication date in feed entries. If `date` is not set, the file mtime is used as a fallback.

Feed registry templates are provided in `starter/registries/`:
- `feed.rss.tt`  -  RSS 2.0 feed at `/feed.rss`
- `feed.atom.tt`  -  Atom feed at `/feed.atom`

Copy them to `lazysite/templates/registries/` to enable feeds on your site.

## The 404 page

`public_html/404.md` is the not-found page. Write and maintain it like any other page:

```markdown
---
title: Page Not Found
subtitle: The page you requested could not be found
---

## Nothing here

The page you were looking for doesn't exist.
Try the navigation above or return to the [home page](/).
```

Delete `404.html` to regenerate it after edits.

## Cache management

Local `.md` pages regenerate automatically when the `.md` file is newer than the cached `.html`. Editing and saving is sufficient  -  no manual step needed.

Remote `.url` pages use TTL-based invalidation (default 1 hour). The stale cache is always served immediately; the refetch happens on the next request after TTL expiry.

To force regeneration of any page:

```bash
# One page
rm public_html/about.html

# All pages (e.g. after a template change)
find public_html -name "*.html" -delete
```

Index pages (`index.md` / `index.html`) are served directly by the web server via `DirectoryIndex` and bypass the processor when the cache exists. After editing `index.md`, delete the cached file manually:

```bash
rm public_html/index.html
```

## Static site generation

Pre-render all pages for static hosting:

```bash
# Build in-place
bash build-static.sh https://example.com

# Build to a separate output directory
bash build-static.sh https://example.com ./dist
```

Deploy the output to GitHub Pages, Netlify, Cloudflare Pages, or any plain web server.

## Link audit

`lazysite-audit.pl` scans the docroot and reports orphaned pages (source files with no inbound links) and broken links (links pointing to pages that do not exist):

```bash
perl lazysite-audit.pl /home/username/web/example.com/public_html
```

Pass `--exclude` to omit specific pages from the orphan report:

```bash
perl lazysite-audit.pl --exclude changelog,contributing /path/to/docroot
```

## Migrating from other tools

Pico CMS
: Content migrates directly. Copy your Pico `content/` files to the docroot and rename `Title:` to `title:` and `Description:` to `subtitle:` in front matter. Replace Pico theme templates with a `lazysite/templates/view.tt` file. One-liner to convert front matter keys across all files: `find public_html -name "*.md" | xargs sed -i 's/^Title:/title:/;s/^Description:/subtitle:/'`

Hugo
: Content files require no changes  -  Hugo and lazysite use the same front matter format. What needs replacing is the template system: `view.tt` replaces your Hugo `baseof.html` or equivalent base template.

## Troubleshooting

### Run the processor manually

The most direct way to diagnose a page error:

```bash
REDIRECT_URL=/about \
DOCUMENT_ROOT=/home/username/web/example.com/public_html \
  perl /home/username/web/example.com/cgi-bin/lazysite-processor.pl
```

Prints full HTML output or Perl errors to the terminal. Adjust `REDIRECT_URL` to the failing page path.

### Check the error log

```bash
tail -50 /home/username/web/example.com/logs/example.com.error.log
```

`End of script output before headers`
: The script crashed before printing anything. Run the processor manually to see the Perl error.

`lazysite: Cannot write cache file ... Fix with: chmod g+ws`
: The web server cannot write the generated `.html` to the docroot. Pages render correctly but are not cached. Fix with:

```bash
chown ispadmin:www-data /home/username/web/example.com/public_html
chmod g+ws /home/username/web/example.com/public_html
```

### Registries not generating

Registries only generate when a page is rendered  -  not on cached serves. If missing, delete the registry file and force a page render:

```bash
rm public_html/llms.txt
rm public_html/index.html
curl -s https://example.com/ > /dev/null
```

## Live demo

The [feature test page](/lazysite-demo) exercises every processor capability  -  site variables, page variables, TT conditionals, fenced divs, code block protection, oEmbed, and more. Each section shows what to expect. A passing test shows the resolved value; a failing test shows a literal `[% tag %]`.

The demo page is itself served via a `.url` file from the lazysite repository, demonstrating that mechanism in production.

## Installation

```bash
sudo bash install.sh
```

Registers a HestiaCP web template. Apply it to a domain, rebuild vhosts, and the processor and starter files are installed. A standalone Apache configuration is also produced.

```bash
sudo bash uninstall.sh
```

Removes Hestia template files only. Deployed domain files are not touched.

## File reference

```
public_html/
  lazysite/
    lazysite.conf       <- site configuration
    templates/
      view.tt         <- site template (edit this)
      registries/
        llms.txt.tt     <- llms.txt registry template
        sitemap.xml.tt  <- sitemap registry template
    themes/             <- theme assets
  assets/
    css/                <- stylesheets
    img/                <- images
    js/                 <- scripts
  cgi-bin/
    lazysite-processor.pl <- processor (do not edit)
  404.md                <- not-found page
  index.md              <- home page
```

[github]: https://github.com/OpenDigitalCC/lazysite
[tt2docs]: https://template-toolkit.org/docs/
