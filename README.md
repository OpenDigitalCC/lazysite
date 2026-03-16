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
- The handler runs `md-processor.pl` which looks for a `.md` source file
- If found, the Markdown is converted to HTML and rendered through a
  Template Toolkit layout
- The result is cached as `.html` alongside the source
- Subsequent requests are served directly from the static cache

## Requirements

- HestiaCP with Apache + PHP-FPM
- Debian / Ubuntu
- `libtext-markdown-perl`
- `libtemplate-perl`

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

## Cache management

Generated `.html` files are cached alongside `.md` sources. To force
regeneration after editing a page:

```bash
rm public_html/about.html
```

To regenerate all pages (after a template change):

```bash
find public_html -name "*.html" -delete
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
      404.md            <- starter 404 page
      index.md          <- starter index page
  docs/
    authoring.md        <- authoring and template integration guide
```

## Licence

MIT
