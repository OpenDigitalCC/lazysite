# md-pages

Pure Markdown content management for Apache and HestiaCP.

Drop `.md` files in your docroot and they are served as fully rendered HTML
pages - no build step, no CMS, no database. Pages are generated on first
request and cached as static HTML.

## Why md-pages

Most content management approaches force a choice between a dynamic CMS
(database, runtime, security surface) and a static site generator (build
pipeline, toolchain, deploy step). md-pages sits between the two.

Content management
: Write pages in Markdown. Drop files in the docroot. Pages are live
  immediately - no publishing step, no build, no deploy command.

Design and content are separated
: The Template Toolkit layout owns the site design. Content authors work
  only in `.md` files. Designers work only in `layout.tt`. Neither needs
  to touch the other's files.

Version control ready
: Everything is a file - Markdown sources, the layout template, the
  processor. The entire site lives in a VCS repository. Content changes,
  design changes, and code changes all have full history.

Fast by default
: Pages are dynamic only on the first request. After that, Apache serves
  plain cached `.html` - no interpreter, no processing, no overhead.
  The best blend of a static site and a dynamic system.

No build or make step
: Write a `.md` file, save it, it is live. Delete the cached `.html` to
  republish after edits. That is the entire workflow.

No database
: Files are the source of truth. Nothing to back up separately, nothing
  to migrate, nothing to corrupt.

Content is portable
: Plain `.md` files are not locked to this system. They work with any
  Markdown processor, any static site generator, any editor. Switching
  tools later does not mean rewriting content.

Works with any deployment workflow
: rsync, git pull, sftp, FTP, scp - however files reach the server,
  md-pages picks them up. It integrates easily into CI/CD pipelines
  or manual workflows equally well.

Cache is transparent
: Generated `.html` files are readable, standard HTML. They can be
  inspected, debugged, or served independently if needed.

Resilient
: If the processor fails for any reason, previously cached `.html` files
  continue to be served unaffected.

Easy to audit
: The processor is a single readable Perl script with no framework
  dependencies beyond three standard Debian packages.

Works alongside static files
: Mix hand-crafted `.html` files and `.md` files in the same docroot
  freely. md-pages only activates when no matching file exists.

## Web server support

md-pages uses standard CGI and error handler mechanisms available in most
web servers.

- Apache 2.4 - supported, HestiaCP installer provided
- Apache without HestiaCP - configure `ErrorDocument 403/404` manually
- Nginx - use `error_page 403 404` to point to the CGI script
- Any web server with CGI support and configurable error handlers should work

## How it works

- Requests for pages with no matching file trigger Apache's 404/403 handler
- The handler runs `md-processor.pl` which looks for a `.md` or `.url` source file
- If found, the Markdown is converted to HTML and rendered through a
  Template Toolkit layout
- The result is cached as `.html` alongside the source
- Subsequent requests are served directly from the static cache

## Requirements

- HestiaCP with Apache + PHP-FPM
- Debian / Ubuntu
- `libtext-multimarkdown-perl`
- `libtemplate-perl`
- `libwww-perl` (for remote `.url` sources and oEmbed)
- `JSON::PP` (Perl core - no separate install needed)

The installer will install missing Perl modules automatically.

## Installation

```bash
git clone https://github.com/OpenDigitalCC/md-pages.git
cd md-pages
sudo bash install.sh
```

Then in HestiaCP:

1. Edit your domain
2. Set the web template to `ssi-md`
3. Save and rebuild

The processor, starter layout, and starter content are installed
automatically on rebuild.

## Getting started

After applying the template to a domain:

1. Edit `public_html/templates/layout.tt` to apply your site design
2. Edit `public_html/index.md` for your home page content
3. Add pages by dropping `.md` files anywhere in the docroot

Pages are available immediately at their extensionless URL:

```
public_html/about.md            -> https://example.com/about
public_html/services/hosting.md -> https://example.com/services/hosting
public_html/services/index.md   -> https://example.com/services/
```

Directory index pages are served when a trailing slash URL is requested.
Create `dirname/index.md` for any directory that needs an index page.

## Page format

```markdown
---
title: Page Title
subtitle: Optional subtitle
---

## Content heading

Page content in standard Markdown.

::: widebox
Styled div - class maps to your CSS.
:::
```

See [docs/authoring.md](docs/authoring.md) for the full authoring and
template integration guide.

## Template Toolkit variables

All pages have access to these standard variables in `layout.tt` and page
content:

- `[% page_title %]` - from front matter `title`
- `[% page_subtitle %]` - from front matter `subtitle`
- `[% content %]` - the converted page body

Variables are processed in two passes - first in the page body, then in
`layout.tt`. This means `[% version %]` works both in `.md` content and
in the layout template.

### Site-wide variables

Variables available on every page are defined in `templates/layout.vars`:

```yaml
site_name: ctrl-exec
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
version: url:https://raw.githubusercontent.com/example/repo/main/VERSION
support_email: hello@example.com
```

Three value types are supported:

Literal string
: `key: value` - used as-is

Environment variable
: `key: ${ENV_VAR}` - interpolated from the Apache CGI environment.
  Multiple vars and mixed text are supported: `${REQUEST_SCHEME}://${SERVER_NAME}`

Remote URL
: `key: url:https://...` - fetched, trimmed, and cached with the page TTL.
  Env var interpolation works inside `url:` values too.

Useful Apache CGI environment variables:

- `${SERVER_NAME}` - domain name e.g. `example.com`
- `${REQUEST_SCHEME}` - `http` or `https`
- `${SERVER_PORT}` - port number
- `${HTTPS}` - `on` if SSL

### Page-scoped variables

Variables available only on a specific page are defined in its front matter
under `tt_page_var`:

```yaml
---
title: Downloads
tt_page_var:
  release_notes: url:https://raw.githubusercontent.com/example/repo/main/CHANGES
  beta: true
---
```

Page variables override site variables of the same name.

### Variable precedence

Site vars → page vars → `page_title`, `page_subtitle`, `content`

## Registries

Registries are generated files derived from page front matter - `llms.txt`,
`sitemap.xml`, or any other format. A page declares which registries it
belongs to via the `register` front matter key:

```yaml
---
title: Installation Guide
subtitle: How to install and configure
register:
  - llms.txt
  - sitemap.xml
---
```

Each registry name maps to a Template Toolkit template in
`templates/registries/`. The template filename without `.tt` is the output
filename written to the docroot root:

```
templates/registries/llms.txt.tt    -> public_html/llms.txt
templates/registries/sitemap.xml.tt -> public_html/sitemap.xml
```

Registries are regenerated on the next page render after the registry TTL
expires (default 4 hours - `$REGISTRY_TTL` in `md-processor.pl`). To force
immediate regeneration delete the output file:

```bash
rm public_html/llms.txt
```

### Registry templates

Registry templates receive these variables:

- `pages` - array of registered page objects
- All site-wide variables from `layout.vars`

Each page object contains:

- `[% page.url %]` - canonical URL path e.g. `/install`
- `[% page.title %]` - from front matter
- `[% page.subtitle %]` - from front matter

Example `llms.txt.tt`:

```
# [% site_name %]

> [% site_name %] documentation and pages.

## Pages

[% FOREACH page IN pages %]
- [[% page.title %]]([% site_url %][% page.url %].md)[% IF page.subtitle %]: [% page.subtitle %][% END %]
[% END %]
```

Example `sitemap.xml.tt`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
[% FOREACH page IN pages %]
  <url>
    <loc>[% site_url %][% page.url %]</loc>
  </url>
[% END %]
</urlset>
```

### Adding a new registry

Drop a `.tt` file in `templates/registries/` - no code changes needed. The
processor picks it up automatically on the next page render after the TTL
expires.

## Embedded media

Pages can embed videos and other media using oEmbed. Any oEmbed-compatible
provider is supported - YouTube, Vimeo, SoundCloud, and self-hosted PeerTube
instances among others.

```markdown
::: oembed
https://peertube.example.com/videos/watch/abc123
:::

::: oembed
https://www.youtube.com/watch?v=abc123
:::
```

The processor fetches the oEmbed endpoint, extracts the provider's iframe
HTML, and bakes it into the cached page. No client-side API calls are made -
the embed is static HTML after the first render.

Known providers (YouTube, Vimeo, SoundCloud, Twitter/X) are looked up
directly. Unknown providers use oEmbed autodiscovery - the video page is
fetched and the `<link rel="alternate" type="application/json+oembed">` tag
is followed to find the endpoint.

If the fetch fails the block renders as a plain link fallback with class
`oembed--failed` for CSS targeting.

Additional providers can be added to `%OEMBED_PROVIDERS` in `md-processor.pl`.



Pages can be sourced from remote Markdown files by creating a `.url` file
containing a URL instead of a `.md` file containing content.

```
public_html/install.url  contains:
https://raw.githubusercontent.com/example/repo/main/docs/install.md
```

This makes `/install` fetch, render, and cache the remote Markdown file.
The remote source is processed through the same pipeline as local files -
YAML front matter, fenced divs, code blocks, and the site template are
all applied.

Remote content is cached as `.html` alongside the `.url` file. The cache
TTL defaults to 1 hour - configured as `$REMOTE_TTL` in `md-processor.pl`.
After the TTL expires the next request silently refetches the source.

If a remote fetch fails, the stale cache is served if available. If there
is no cache, an error block is rendered in the page.

To force immediate refresh of a remote page, delete the cached `.html`:

```bash
rm public_html/install.html
```

A GitHub Actions workflow can automate this after a push to the source
repository using `ssh` to delete the cached file on the server.

## Cache management

Local `.md` pages
: The cache is invalidated automatically by mtime comparison. When the
  `.md` file is newer than the cached `.html`, the page is regenerated
  on the next request. Editing a `.md` file and saving it is sufficient
  to trigger regeneration - no manual step needed.

Remote `.url` pages
: The cache is invalidated by TTL (default 1 hour - `$REMOTE_TTL` in
  `md-processor.pl`). The stale cache is always served immediately - the
  refetch happens on the first request after TTL expiry, transparent to
  the user.

Page-level TTL override
: Any page can set its own TTL via the `ttl` front matter key. When set,
  the page uses TTL-based cache invalidation instead of mtime comparison.
  Useful for pages that pull remote data via `tt_page_var` and need
  frequent refresh.

```yaml
---
title: Downloads
ttl: 300
---
```

This page regenerates every 5 minutes regardless of whether the `.md`
file has changed.

To force regeneration of any page regardless of cache state:

```bash
rm public_html/about.html
```

To regenerate all pages (for example after a template change):

```bash
find public_html -name "*.html" -delete
```

## Troubleshooting

### Run the processor manually

The most direct way to diagnose any page error is to run the processor from
the command line, simulating an Apache request:

```bash
REDIRECT_URL=/install \
DOCUMENT_ROOT=/home/username/web/example.com/public_html \
  perl /home/username/web/example.com/cgi-bin/md-processor.pl
```

This prints the full HTML output (or any Perl errors) directly to the
terminal. Replace `/install` with the failing page path and adjust the
`DOCUMENT_ROOT` to match your domain.

To inspect a specific section of the output:

```bash
REDIRECT_URL=/install \
DOCUMENT_ROOT=/home/username/web/example.com/public_html \
  perl /home/username/web/example.com/cgi-bin/md-processor.pl | grep -A5 -B5 'keyword'
```

### Syntax check the script

```bash
perl -c /home/username/web/example.com/cgi-bin/md-processor.pl
```

`syntax OK` means Perl can parse the script. Errors here will show the
line number and nature of the problem.

### Check the Apache error log

```bash
tail -50 /home/username/web/example.com/logs/example.com.error.log
```

Key messages to look for:

`End of script output before headers`
: The script crashed before printing anything. Run the processor manually
  (above) to see the Perl error.

`Cannot serve directory ... No matching DirectoryIndex`
: The index page is not being found. Ensure `DirectoryIndex index.html`
  is in the vhost config and that the 403 handler is set.

`AH01276: Cannot serve directory`
: Same as above - the 403 error handler should fire and generate
  `index.html` from `index.md` on first request.

`md-pages: Cannot write cache file ... Fix with: chmod g+w`
: The web server cannot write the generated `.html` file to the docroot.
  The page will still render correctly but will not be cached - every
  request will regenerate it until permissions are fixed.

### Cache write permission error

The most common setup issue. The web server user (`www-data`) needs write
permission on the docroot to create cached `.html` files.

When this happens the page renders correctly for visitors but the Apache
error log will contain:

```
md-pages: Cannot write cache file /path/to/page.html: Permission denied
- page will render uncached. Fix with: chmod g+w /path/to/
```

Fix with:

```bash
chmod g+w /home/username/web/example.com/public_html
```

This is reset on every HestiaCP domain rebuild. To reapply across all
domains after a rebuild:

```bash
chmod g+w /home/username/web/*/public_html
```

Note: the `ssi-md.sh` hook sets this automatically when the template is
first applied to a domain. It only runs on apply, not on subsequent
rebuilds.

### Template not found

If the processor crashes with a Template error, check the layout file exists:

```bash
ls /home/username/web/example.com/public_html/templates/layout.tt
```

If missing, the `ssi-md.sh` hook did not run or the file was deleted.
Reinstall it from the package:

```bash
cp /usr/local/hestia/data/templates/web/apache2/php-fpm/files/layout.tt \
   /home/username/web/example.com/public_html/templates/layout.tt
```

### Subdirectory permissions

When pages are in subdirectories (`docs/`, `services/` etc.), the processor
creates those directories automatically. However the group ownership must
match the docroot for `www-data` to write into them.

If pages in subdirectories render but don't cache, fix the directory:

```bash
chown $(stat -c '%U' public_html):$(stat -c '%G' public_html) public_html/docs
chmod g+w public_html/docs
```

The error log will contain the fix command if this is the cause:

```
md-pages: Cannot write cache file .../docs/install.html: Permission denied
- page will render uncached. Fix with: chown ...
```

### Access log status codes

The processor emits a `Status: 200 OK` CGI header for successfully rendered
pages and `Status: 404 Not Found` for genuine missing pages. Apache respects
these headers and logs the correct status.

A 404 in the access log is always a real missing page - no `.md` or `.url`
source file exists for that path. Pages rendered by the processor appear as
200.

Note: cached `.html` files served directly by Apache (on subsequent requests)
have always logged 200 correctly. The status header fix applies only to the
first render of each page.

### Registries not generating

Registries are only generated when a page is rendered - they are not
generated on cached page serves. If registries are missing:

1. Delete the registry file to clear any stale TTL state:
   ```bash
   rm public_html/llms.txt
   ```
2. Force a page render by deleting a cached page:
   ```bash
   rm public_html/index.html
   ```
3. Request the page via curl (bypasses browser cache):
   ```bash
   curl -s https://example.com/ > /dev/null
   ```

Check the error log for any registry errors:

```bash
grep "Registry\|registry" logs/example.com.error.log
```

## Link audit

`md-pages-audit.pl` scans your docroot and reports orphaned pages and broken
links.

Orphaned pages
: `.md` or `.url` files that exist but are not linked from any scanned file.
  These may be redundant or simply missing from navigation.

Broken links
: Links in `.md` or template files pointing to pages that do not exist.

```bash
perl md-pages-audit.pl /home/username/web/example.com/public_html
```

The audit scans `.md` files, `.tt` templates (including `layout.tt` and
registry templates), and cached `.html` files for `.url` pages. External
links, assets, and image files are ignored.

`index` and `404` are always excluded from the orphan report. Additional
exclusions can be passed on the command line:

```bash
perl md-pages-audit.pl --exclude changelog,contributing /path/to/docroot
```

Or via a file with one path per line:

```bash
perl md-pages-audit.pl --exclude-file exclusions.txt /path/to/docroot
```

## Security

### Path traversal

`sanitise_uri` rejects null bytes, `..` path segments, and suspicious
characters before constructing filesystem paths. After construction, each
path is verified with `realpath` to confirm it resolves within `$DOCROOT`.
Symlinks pointing outside the docroot are rejected.

The same check is applied inside `write_html` before any file is written,
guarding against symlink-based overwrite attacks on the cache output path.

### Template Toolkit injection

All values extracted from YAML front matter - including `title`, `subtitle`,
and `tt_page_var` entries - have TT directive markers (`[%` and `%]`) stripped
before entering the template context. `register` list items are stripped at
parse time. This prevents authored content from injecting TT directives into
the rendering pipeline.

### Environment variable interpolation

The `${VAR}` interpolation in `layout.vars` is restricted to an explicit
allowlist: `SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`,
`DOCUMENT_ROOT`, `SERVER_ADMIN`. Request-supplied headers (`HTTP_*` variables)
are not interpolated regardless of what appears in `layout.vars`.

### Fenced div class names

The class name following `:::` is validated against `/\A[\w][\w-]*\z/` before
use. Blocks with class names containing characters outside word characters and
hyphens are rejected - the content renders without a wrapper div and a warning
is written to the error log.

### oEmbed JSON parsing

oEmbed provider responses are parsed with `JSON::PP` (Perl core module) rather
than regex extraction. The `html` field from the parsed response is injected
into the page. Provider responses are trusted as-is - restrict `%OEMBED_PROVIDERS`
in `md-processor.pl` to known hosts if untrusted providers are a concern in
your deployment.

## Uninstall

```bash
sudo bash uninstall.sh
```

Removes Hestia template files only. Deployed domain files are not touched.

## Repository structure

```
md-pages/
  install.sh
  uninstall.sh
  md-pages-audit.pl   <- link audit utility
  template/
    ssi-md.tpl          <- Apache vhost template (HTTP)
    ssi-md.stpl         <- Apache vhost template (HTTPS)
    ssi-md.sh           <- Hestia domain hook
    files/
      md-processor.pl   <- CGI processor
      layout.tt         <- starter site template
      layout.vars       <- starter site-wide TT variables
      404.md            <- starter 404 page
      index.md          <- starter index page
      registries/
        llms.txt.tt     <- starter llms.txt registry template
        sitemap.xml.tt  <- starter sitemap registry template
  docs/
    authoring.md        <- authoring and template integration guide
```

## Licence

MIT
