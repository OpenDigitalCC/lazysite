# md-pages

Markdown-driven pages for HestiaCP with Template Toolkit rendering.

Drop `.md` files in your docroot and they are served as fully rendered HTML
pages - no build step, no CMS, no database. Pages are generated on first
request and cached as static HTML.

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
