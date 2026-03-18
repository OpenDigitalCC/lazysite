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

## Motivations

md-pages grew out of a specific frustration with the available options for
managing a small set of sites on a personal hosting infrastructure.

### Starting point: SSI

The starting point was Apache Server Side Includes. SSI is elegant for what
it does - a standard mechanism built into Apache for composing pages from
fragments, with no runtime dependency beyond the web server itself. Header,
footer, navigation as separate files, included at serve time. Fast, simple,
no moving parts.

The problem is content management. SSI handles page composition well but
has nothing to say about how you author or manage the content that goes into
those pages. You end up writing HTML directly, which is fine for templates
but poor for page content. Any non-trivial site accumulates HTML files that
are tedious to write and update.

### What was needed

The requirements that shaped md-pages:

Speed
: Pages should be fast. Not "fast enough" - actually fast. A CGI process on
  every request is not fast. Static file serving is fast. The caching model
  means the CGI fires once per page, then Apache serves static HTML. The
  common case is a file read, not a process fork.

Simplicity
: No database. No admin interface. No framework to learn. No build pipeline
  to maintain. Drop a file, get a page. The entire system is one Perl script
  that can be read and understood in an afternoon.

Markdown
: Content should be written in Markdown. Not because Markdown is perfect,
  but because it is the established lingua franca for structured plain text.
  It works in any editor, versions cleanly in git, and is readable without
  rendering. Pandoc-style fenced divs for the cases where you need a
  styled wrapper without writing HTML.

Control where you want it
: The layout template is a file you own and edit directly. The CSS is your
  CSS. The HTML structure is yours. md-pages renders Markdown into a slot in
  your template - it does not impose a theme, a component model, or a
  styling convention. If you know HTML and CSS you are not constrained.

Sensible defaults
: The parts you do not want to think about should work without configuration.
  Caching. Cache invalidation on file edit. Subdirectory creation with correct
  permissions. A starter 404 page. A starter layout. These should all just
  work on first install.

Same method everywhere
: A page authored for one site should work on any other site running md-pages.
  The front matter format, the fenced div syntax, the URL structure - all
  consistent. Moving content between sites is a file copy.

Version control as the content store
: The entire site - content, templates, variables, processor - lives in a git
  repository. Every change has history. Deploying is a file copy. Rolling
  back is a file copy. No database export/import, no CMS backup, no
  proprietary format.

### Integration with HestiaCP

HestiaCP is the control panel in use on the hosting infrastructure. It has
a web template system that generates Apache vhost configs. md-pages plugs
into this as a named template - apply it to a domain, rebuild, and the
processor and starter files are installed automatically. The same installer
also produces clean configurations for standalone Apache outside HestiaCP.

The HestiaCP integration is additive. md-pages works without it.

### What emerged during development

Several things were not in the original plan but followed naturally:

Remote sources via `.url` files - pulling documentation directly from a
GitHub repository rather than duplicating it. The documentation lives with
the code, the site always shows the current version.

Template Toolkit variables fetched from remote URLs - a version number from
a `VERSION` file, release metadata from a GitHub API endpoint, baked into
the cached page at render time rather than fetched client-side.

The registry system - `llms.txt` and `sitemap.xml` generated from page front
matter, updated automatically when pages are rendered. Adding a new registry
format requires only a template file.

oEmbed - embedding PeerTube and other video providers with a one-line syntax,
the iframe baked into the cache.

The link audit tool - a maintenance utility that emerged from the need to
identify orphaned pages and broken links as the site grew.

The Docker staging workflow - a natural consequence of the file-based
architecture. Stage in a container, rsync the source files to production,
let the cache warm on first visit.

Each of these followed from the same principle: the mechanism should be
simple, the output should be static where possible, and the operator should
retain control.



md-pages suits a specific use case. These alternatives may be a better fit
depending on your requirements.

Hugo
: A static site generator. Build step produces a complete static site from
  Markdown sources. Fast, mature, large ecosystem. Better choice if you want
  a full build pipeline, complex themes, multi-language support, or are
  comfortable with a Go toolchain. No server-side processing after build.

Pico CMS
: A flat-file PHP CMS. Drop Markdown files in a directory and pages appear -
  similar philosophy to md-pages but PHP-based with a plugin ecosystem and
  admin themes. Better choice if you want a richer authoring experience or
  plugins for things like search, without a database. Requires PHP on every
  request.

Jekyll
: Ruby-based static site generator, well-established in the GitHub Pages
  ecosystem. Good choice if your content lives on GitHub and you want free
  hosting with automatic builds on push. Build step required.

WordPress
: Full CMS with database, admin UI, and vast plugin ecosystem. Better choice
  for non-technical authors, multi-user publishing workflows, e-commerce, or
  any site needing dynamic content beyond what static caching provides.

Publii
: Desktop app that generates a static site. Good choice if authors prefer a
  GUI and the site is maintained by one person. No server-side processing.

md-pages is most appropriate when content is managed via VCS, authors are
comfortable with Markdown and a text editor, and the simplicity of no
database and no build step is valued over a richer feature set.

### Migrating from Pico CMS

Pico content migrates directly to md-pages with minimal changes. Pico uses
the same Markdown files with YAML front matter:

```yaml
---
Title: My Page
Description: A short description
---
Content here.
```

To migrate:

- Copy your Pico `content/` files to the md-pages docroot
- Rename `Title:` to `title:` and `Description:` to `subtitle:` in front matter
  (md-pages uses lowercase keys)
- Remove any Pico-specific front matter keys that have no equivalent
- Replace Pico theme templates with a `layout.tt` template

A one-liner to lowercase the common front matter keys across all files:

```bash
find public_html -name "*.md" | \
  xargs sed -i 's/^Title:/title:/;s/^Description:/subtitle:/'
```

### Migrating from Hugo

Hugo Markdown content uses the same front matter format. The content files
themselves require no changes. What does need replacing is the Hugo template
system - Hugo uses Go templates, md-pages uses Template Toolkit. The
`layout.tt` file replaces your Hugo `baseof.html` or equivalent base template.



- Requests for pages with no matching file trigger Apache's 404/403 handler
- The handler runs `md-processor.pl` which looks for a `.md` or `.url` source file
- If found, the Markdown is converted to HTML and rendered through a
  Template Toolkit layout
- The result is cached as `.html` alongside the source
- Subsequent requests are served directly from the static cache

## Requirements

- Apache 2.4 with CGI support and `ErrorDocument` configuration
- Debian / Ubuntu (or any Linux with the Perl modules below)
- `libtext-multimarkdown-perl`
- `libtemplate-perl`
- `libwww-perl` (for remote `.url` sources and oEmbed)
- `JSON::PP` (Perl core - no separate install needed)

HestiaCP is supported with a dedicated installer. For other environments
see the manual installation section below.

## Installation

### HestiaCP

The installer registers md-pages as a HestiaCP web template. Once installed,
apply it to any domain from the control panel and the processor and starter
files are deployed automatically on rebuild.

```bash
git clone https://github.com/OpenDigitalCC/md-pages.git
cd md-pages
sudo bash install.sh
```

Then in HestiaCP:

1. Edit your domain
2. Set the web template to `ssi-md`
3. Save and rebuild

### Manual Apache installation

For Apache without HestiaCP, install the Perl dependencies and configure
the vhost manually:

```bash
apt install libtext-multimarkdown-perl libtemplate-perl libwww-perl
```

Copy `md-processor.pl` to your `cgi-bin/` directory and make it executable:

```bash
cp template/files/md-processor.pl /var/www/example.com/cgi-bin/
chmod 755 /var/www/example.com/cgi-bin/md-processor.pl
```

Copy the starter templates to your docroot:

```bash
mkdir -p /var/www/example.com/public_html/templates/registries
cp template/files/layout.tt       /var/www/example.com/public_html/templates/
cp template/files/layout.vars     /var/www/example.com/public_html/templates/
cp template/files/registries/*.tt /var/www/example.com/public_html/templates/registries/
cp template/files/404.md          /var/www/example.com/public_html/
cp template/files/index.md        /var/www/example.com/public_html/
```

Add to your Apache vhost configuration:

```apache
DirectoryIndex index.html index.htm
AddOutputFilter INCLUDES .shtml
ErrorDocument 403 /cgi-bin/md-processor.pl
ErrorDocument 404 /cgi-bin/md-processor.pl

<Directory /var/www/example.com/public_html>
    Options +Includes -Indexes +ExecCGI
    AllowOverride All
</Directory>
```

Ensure the web server user can write to the docroot:

```bash
chown -R www-data:www-data /var/www/example.com/public_html
chmod g+w /var/www/example.com/public_html
```


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

### Using an AI assistant

`docs/ai-briefing.md` is a concise reference document covering the full
system - layout variables, front matter, Markdown elements, URL structure,
and file locations. Feed it to an AI assistant (Claude, ChatGPT, etc.) at
the start of a session to enable it to help with layout design, page
authoring, and `layout.vars` configuration without needing to explain the
system each time.

In Claude Projects, save it as a project document. For other AI tools,
paste it as context at the start of the conversation.

## Designing the layout template

`templates/layout.tt` is the single file that controls the appearance of
every page. It is the integration point for web designers. A minimal working
example is provided in `template/files/layout.tt` in this repository - it
produces a bare but functional HTML page and is intended as a starting point,
not a finished design.

### What the template receives

Every page render passes these variables to the template:

`[% page_title %]`
: The page title from front matter.

`[% page_subtitle %]`
: The page subtitle from front matter. May be empty - test with `[% IF page_subtitle %]`.

`[% content %]`
: The converted page body as HTML. Output with `[% content %]` - TT does not
  escape this value, which is correct since it is already HTML.

Plus any site-wide variables defined in `layout.vars`.

### Minimal template structure

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[% page_title %] — [% site_name %]</title>
    <link rel="stylesheet" href="/assets/css/main.css">
</head>
<body>

<header>
    <a href="/">[% site_name %]</a>
    <nav>
        <a href="/about">About</a>
        <a href="/docs/">Docs</a>
    </nav>
</header>

<main>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]
    <p class="subtitle">[% page_subtitle %]</p>
    [% END %]
    [% content %]
</main>

<footer>
    <p>&copy; 2026 [% site_name %]</p>
</footer>

</body>
</html>
```

### After changing the template

Delete all cached `.html` files to force regeneration:

```bash
find public_html -name "*.html" -delete
```

Pages regenerate on next request. On a live site with many pages, stagger
this or use curl to pre-warm the cache after deploying a new template.



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

### Advanced Template Toolkit usage

TT variables are not limited to simple strings. A `url:` value that returns
JSON can be decoded and used as a data structure in templates, enabling loops,
conditionals, and dynamic list rendering - all baked into the cached page at
render time.

#### Fetching and looping over JSON data

Fetch a JSON feed via `tt_page_var` and decode it in the template:

```yaml
---
title: News
tt_page_var:
  news_json: url:https://example.com/api/news.json
---
```

In the page body, decode and loop:

```
[% USE JSON( pretty => 0 ) %]
[% news = JSON.deserialize(news_json) %]
[% FOREACH item IN news.items %]
<article>
  <h2><a href="[% item.url %]">[% item.title %]</a></h2>
  <p>[% item.summary %]</p>
  <time>[% item.date %]</time>
</article>
[% END %]
```

The same approach works in `layout.tt` using a site-wide variable from
`layout.vars`:

```yaml
version_json: url:https://api.github.com/repos/example/repo/releases/latest
```

Then in `layout.tt`:

```
[% USE JSON( pretty => 0 ) %]
[% release = JSON.deserialize(version_json) %]
<span class="version">[% release.tag_name %]</span>
```

#### Conditionals

```
[% IF beta %]
<div class="notice">This page documents a beta feature.</div>
[% END %]
```

#### Building navigation from a list

Define a nav structure in `layout.vars`:

```yaml
nav_json: url:https://example.com/nav.json
```

Or as a literal in `layout.tt` directly:

```
[% nav = [
    { label => 'Home',    url => '/' },
    { label => 'Docs',    url => '/docs/' },
    { label => 'Install', url => '/install' },
] %]
<nav>
[% FOREACH item IN nav %]
  <a href="[% item.url %]">[% item.label %]</a>
[% END %]
</nav>
```

#### Notes on TT in page content

TT is processed in two passes - first in the page body, then in `layout.tt`.
The `USE JSON` directive and variable assignments made in the body are local
to that pass and not available in the layout. For data needed in both the
page body and the layout, set it as a site-wide variable in `layout.vars`.

Full Template Toolkit documentation is at [https://template-toolkit.org/docs/][tt2docs].

[tt2docs]: https://template-toolkit.org/docs/



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

## Static site generation

md-pages can generate a complete static site - all pages pre-rendered to
HTML - for deployment to static hosting such as GitHub Pages, Netlify,
Cloudflare Pages, or any plain web server without CGI support.

`build-static.sh` processes all `.md` and `.url` files in the docroot,
simulating the Apache CGI environment so that `layout.vars` variables like
`${SERVER_NAME}` resolve correctly.

```bash
# Build in-place
bash build-static.sh https://example.com

# Build to a separate output directory
bash build-static.sh https://example.com ./dist
```

The base URL argument sets `REQUEST_SCHEME` and `SERVER_NAME` for the build,
ensuring `site_url` and any other environment-derived variables in
`layout.vars` resolve to the correct values for the target deployment.

With a separate output directory, source `.md` and `.url` files are excluded
from the output - only the generated `.html` files, assets, and templates
are included.

Run without arguments for full usage instructions:

```bash
bash build-static.sh
```

### Deploying the static output

```bash
rsync -av --delete ./dist/ user@host:/var/www/html/
```

### Static hosting services

The output directory is a standard static site. Deploy to:

- GitHub Pages - push the output directory to a `gh-pages` branch or `docs/`
- Netlify / Cloudflare Pages - point to the output directory
- Amazon S3 - sync with `aws s3 sync`
- Any web server - rsync or copy the output directory

### Staging workflow

The static build also provides a simple staging approach. Build locally
or in a container against the production URL, verify the output, then
rsync only the source files to the live server:

```bash
# Verify locally against production URL
bash build-static.sh https://example.com ./dist

# Deploy source files only - live server generates its own cache
rsync -av --exclude="*.html" ./public_html/ user@host:/path/to/public_html/
```

The live server regenerates `.html` cache files from the deployed `.md`
sources on first request. No build artefacts are transferred - the deploy
is purely source files.



A Docker Compose setup provides a self-contained md-pages environment
without requiring Apache or HestiaCP on the host. This is useful for local
development, testing, or as a simple standalone deployment.

It also provides a practical staging workflow: develop and preview content
in the container, then deploy to production with a simple file copy.

### docker-compose.yml

```yaml
services:
  web:
    image: debian:bookworm-slim
    ports:
      - "8080:80"
    volumes:
      - ./site:/var/www/html
      - ./cgi-bin:/usr/lib/cgi-bin
    command: >
      bash -c "
        apt-get update -qq &&
        apt-get install -y -qq apache2 libtext-multimarkdown-perl
          libtemplate-perl libwww-perl &&
        a2enmod cgi includes &&
        cp /usr/lib/cgi-bin/md-processor.pl /usr/lib/cgi-bin/ &&
        cat > /etc/apache2/sites-available/000-default.conf << 'EOF'
        <VirtualHost *:80>
          DocumentRoot /var/www/html
          ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/
          DirectoryIndex index.html index.htm
          ErrorDocument 403 /cgi-bin/md-processor.pl
          ErrorDocument 404 /cgi-bin/md-processor.pl
          <Directory /var/www/html>
            Options +Includes -Indexes +ExecCGI
            AllowOverride All
          </Directory>
        </VirtualHost>
EOF
        chown -R www-data:www-data /var/www/html &&
        chmod g+w /var/www/html &&
        apache2ctl -D FOREGROUND
      "
```

Mount your content directory as `/var/www/html` and the processor as
`/usr/lib/cgi-bin/md-processor.pl`.

### Staging to production workflow

The Docker volume is your working site. When ready to deploy, copy the
source files (not the cached `.html` files) to production:

```bash
rsync -av --exclude="*.html" \
  ./site/ \
  user@production:/home/user/web/example.com/public_html/
```

The `--exclude="*.html"` ensures cached pages are not copied - they
regenerate automatically on first request on the production server. This
keeps the deploy clean and avoids serving stale cached content.

To also exclude the Archive directory if present:

```bash
rsync -av --exclude="*.html" --exclude="Archive/" \
  ./site/ \
  user@production:/home/user/web/example.com/public_html/
```

The production server generates fresh `.html` cache files from the
deployed `.md` sources on first visit. The deploy is effectively a file
copy - no build step, no restart, no database migration.

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
  build-static.sh     <- static site generator
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
    ai-briefing.md      <- AI assistant briefing for site creation
```

## Licence

MIT

## AI assistance

md-pages was developed interactively with Claude (Anthropic). Architecture,
design decisions, security review, and deployment were directed by the author.
Claude assisted with code generation, documentation, and iterative refinement
throughout development.
