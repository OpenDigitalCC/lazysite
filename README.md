# lazysite

Markdown-driven pages for any CGI-capable web server. No build step, no
database, no CMS. Drop a `.md` file in your docroot and it is served as
a fully rendered HTML page. The first request generates the HTML and
caches it; every subsequent request is a plain static file.

## Features

Content
- Markdown pages with YAML front matter
- Template Toolkit variables in pages and layouts
- Fenced divs, oEmbed, content includes
- Remote pages (`.url` files that fetch Markdown from a URL)
- Page scan for blog/news index pages
- Registry files: sitemap.xml, llms.txt, RSS, Atom
- TTL-based cache and API/raw output modes

Layouts and themes
- Template Toolkit layout templates (`layout.tt`)
- Themes nest under `lazysite/layouts/LAYOUT/themes/THEME/`
- Design tokens auto-emit as CSS custom properties (`theme.config`)
- Built-in fallback so sites work with zero configuration

Manager
- Browser-based admin at `/manager`
- Config, Files, Nav, Plugins, Themes, Users, and Cache pages
- Admin bar on site pages for manager users

Authentication
- Built-in cookie auth (`lazysite-auth.pl`) with users and groups
- Drop-in replacement by any proxy that sets `X-Remote-*` headers
- Per-page `auth:` and `auth_groups:` front matter

Forms
- Inline `:::form` blocks with field validation
- Named dispatch handlers (SMTP, file storage, webhooks)
- Honeypot, HMAC timestamp token, and rate limiting built in

Payment
- x402 payment flow support via `payment:` front matter

Plugins
- Auto-discovery of CGI scripts and tools via `--describe` JSON
- Enable, disable, and configure from the manager

Operations
- Structured logging (text or JSON, env or config)
- Link audit (orphaned pages, broken internal links)
- Static site generation for GitHub Pages, Netlify, etc.

## Quick start

    git clone https://github.com/OpenDigitalCC/lazysite.git
    cd lazysite
    perl tools/lazysite-server.pl

Open http://localhost:8080/ to browse the starter site.

## Installation

    sudo bash install.sh --docroot /path/to/public_html \
                         --cgibin /path/to/cgi-bin \
                         --domain example.com

The installer is upgrade-aware: re-run against the same `--docroot`
to apply a new release. Seed files you've edited are preserved;
backups accumulate at `{docroot}/lazysite/backups/`. Use
`--dry-run` to preview an upgrade, `--restore` to roll back.

HestiaCP users: see `installers/hestia/`. Docker: see `installers/docker/`.

Full installation details in
[starter/docs/install.md](starter/docs/install.md).

## Documentation

Browse locally via the dev server, or read the Markdown directly:

- `starter/docs/install.md` - installation
- `starter/docs/authoring.md` - writing content
- `starter/docs/configuration.md` - lazysite.conf, nav, plugins
- `starter/docs/layouts.md` - layouts and themes
- `starter/docs/manager.md` - the manager UI
- `starter/docs/auth.md` - authentication
- `starter/docs/forms.md` - contact forms
- `starter/docs/payment.md` - x402 payment
- `starter/docs/development.md` - dev server, rsync, troubleshooting
- `starter/docs/reference.md` - keys, variables, file locations

AI-assistant briefings:

- `starter/docs/ai-briefing-authoring.md`
- `starter/docs/ai-briefing-layouts.md`
- `starter/docs/ai-briefing-configuration.md`
- `starter/docs/ai-briefing-development.md`

## Layouts and themes

Ready-to-use layouts and themes live in the companion repo
[lazysite-layouts][layouts]. Install a theme zip via the
manager Themes page, which unpacks it under
`lazysite/layouts/LAYOUT/themes/THEME/`. Layouts are installed
manually or via the "Install from Releases" browser.

## Requirements

- Perl 5.10 or later
- Apache or nginx with CGI support
- Template Toolkit (`libtemplate-perl` on Debian)
- Optional: `IO::Socket::SSL` for HTTPS SMTP delivery

## Licence

MIT. See [LICENSE](LICENSE).

[layouts]: https://github.com/OpenDigitalCC/lazysite-layouts
