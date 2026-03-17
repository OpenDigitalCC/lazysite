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
: The entire processor is around 150 lines of readable Perl with no
  framework dependencies beyond two standard Debian packages.

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
- `libwww-perl` (for remote `.url` sources)

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
```

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

### Site-wide variables (`tt_site_var`)

Variables available on every page are defined in `templates/layout.vars`:

```yaml
site_name: My Site
version: url:https://raw.githubusercontent.com/example/repo/main/VERSION
support_email: hello@example.com
```

Values prefixed with `url:` are fetched from the remote URL and trimmed.
Values without a prefix are used as literal strings.

Use anywhere in `layout.tt` or page content:

```
[% site_name %]
[% version %]
```

### Page-scoped variables (`tt_page_var`)

Variables available only on a specific page are defined in its front matter:

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

## Remote sources

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
: The cache is invalidated by TTL (default 1 hour). The stale cache is
  always served immediately - the refetch happens on the first request
  after TTL expiry, transparent to the user.

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
  docs/
    authoring.md        <- authoring and template integration guide
```

## Licence

MIT
