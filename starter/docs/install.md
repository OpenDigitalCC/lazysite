---
title: Installation
subtitle: Requirements, server setup, and getting started.
register:
  - sitemap.xml
  - llms.txt
---

## Why lazysite

Drop `.md` files in your docroot and they are served as fully rendered
HTML pages - no build step, no CMS, no database. Pages are generated on
first request and cached as static HTML. Content is portable, version
control friendly, and works with any deployment workflow.

For the full motivation behind lazysite, see [Motivation](https://lazysite.io/motivation).

## Web server support

lazysite uses standard CGI and error handler mechanisms available in most
web servers.

- Apache 2.4 - supported, HestiaCP installer provided
- Apache without HestiaCP - configure `FallbackResource` manually
- Nginx - use `error_page 403 404` to point to the CGI script
- Any web server with CGI support and configurable error handlers should work

## Requirements

- Apache 2.4 with CGI support and `FallbackResource` configuration
- Debian / Ubuntu (or any Linux with the Perl modules below)
- `libtext-multimarkdown-perl`
- `libtemplate-perl`
- `libwww-perl` (for remote `.url` sources and oEmbed)
- `JSON::PP` (Perl core - no separate install needed)

Optional:

- `libtemplate-plugin-json-escape-perl` (required for the search index)

HestiaCP is supported with a dedicated installer. For other environments
see the manual installation section below.

## Installation

### HestiaCP

The installer registers lazysite as a HestiaCP web template. Once installed,
apply it to any domain from the control panel and the processor and starter
files are deployed automatically on rebuild.

```bash
git clone https://github.com/OpenDigitalCC/lazysite.git
cd lazysite
sudo bash install.sh --docroot /path/to/public_html --cgibin /path/to/cgi-bin
```

`install.sh` is a thin wrapper around `install.pl`; the Perl
installer reads `release-manifest.json` and tracks installed
state at `{docroot}/lazysite/.install-state.json` so re-runs
upgrade in place without losing content you've edited. See
[Upgrading](#upgrading) below.

Then in HestiaCP:

1. Edit your domain
2. Set the web template to `lazysite`
3. Save and rebuild

### Manual Apache installation

For Apache without HestiaCP, install the Perl dependencies and configure
the vhost manually:

```bash
apt install libtext-multimarkdown-perl libtemplate-perl libwww-perl
```

Copy `lazysite-processor.pl` to your `cgi-bin/` directory and make it executable:

```bash
cp lazysite-processor.pl /var/www/example.com/cgi-bin/
chmod 755 /var/www/example.com/cgi-bin/lazysite-processor.pl
```

Copy the starter files to your docroot:

```bash
mkdir -p /var/www/example.com/public_html/lazysite/templates/registries
mkdir -p /var/www/example.com/public_html/lazysite/themes
cp starter/lazysite.conf.example   /var/www/example.com/public_html/lazysite/lazysite.conf
cp starter/registries/*.tt         /var/www/example.com/public_html/lazysite/templates/registries/
cp starter/404.md                  /var/www/example.com/public_html/
cp starter/index.md                /var/www/example.com/public_html/
```

Add to your Apache vhost configuration:

```apache
DirectoryIndex index.html index.htm
FallbackResource /cgi-bin/lazysite-processor.pl

<Location /lazysite>
    Require all denied
</Location>

<Directory /var/www/example.com/public_html>
    Options -Indexes +ExecCGI
    AllowOverride All
</Directory>
```

Ensure the web server user can write to the docroot:

```bash
chown ispadmin:www-data /var/www/example.com/public_html
chmod g+ws /var/www/example.com/public_html
```

The setgid bit (`s`) ensures new subdirectories created by the processor
inherit the `www-data` group automatically.

## Getting started

### Local development

Clone the repository and run the built-in development server:

    git clone https://github.com/OpenDigitalCC/lazysite.git
    cd lazysite
    perl tools/lazysite-server.pl

Open http://localhost:8080/ to browse the starter site. No Apache
configuration required for local development.

### After installing on a server

1. Install a view from [lazysite-views][views] or write your own `view.tt`
2. Edit `public_html/lazysite/nav.conf` to define your site navigation
3. Edit `public_html/index.md` for your home page content
4. Add pages by dropping `.md` files anywhere in the docroot

Pages are available immediately at their extensionless URL:

    public_html/about.md            -> https://example.com/about
    public_html/services/hosting.md -> https://example.com/services/hosting
    public_html/services/index.md   -> https://example.com/services/

Directory index pages are served when a trailing slash URL is requested.
Create `dirname/index.md` for any directory that needs an index page.

### Using an AI assistant

Four audience-specific briefings live under `starter/docs/`:

- `ai-briefing-authoring.md` - writing content
- `ai-briefing-views.md` - designing themes
- `ai-briefing-configuration.md` - configuring a site
- `ai-briefing-development.md` - working on the codebase

Feed the relevant briefing to an AI assistant at the start of a
session to enable help without needing to explain the system each
time. In Claude Projects, save it as a project document. For other
AI tools, paste it as context at the start of the conversation.

## Upgrading

Re-run `install.sh` against the same `--docroot` and `--cgibin` to
upgrade. Seed files you have edited (starter pages, docs) are
preserved; code files (processor, plugins, manager UI) are
always refreshed.

```bash
sudo bash install.sh --docroot /path/to/public_html --cgibin /path/to/cgi-bin
```

Before applying an upgrade, the installer creates a backup
tarball at `{docroot}/lazysite/backups/`. Inspect the plan
before committing:

```bash
bash install.sh --docroot /path/to/public_html --cgibin /path/to/cgi-bin --dry-run
```

`backup_retention` in `lazysite.conf` controls how many
backups are kept (default 3; 0 = keep all).

### If upgrade goes wrong

```bash
bash install.sh --docroot /path/to/public_html --restore
```

Restores the most recent backup. For a specific backup:

```bash
bash install.sh --docroot /path/to/public_html --restore --backup /path/to/backup.tar.gz
```

List available backups:

```bash
bash install.sh --docroot /path/to/public_html --list-backups
```

Restore does not touch runtime state (auth users, cache, logs)
and invalidates the rendered HTML cache afterwards.

## Uninstall

    sudo bash uninstall.sh

Removes Hestia template files only. Deployed domain files are not touched.

## File reference

    public_html/
      lazysite/
        lazysite.conf         <- site configuration
        nav.conf              <- navigation (YAML)
        themes/
          THEME/
            view.tt           <- theme template
            assets/           <- theme assets
          manager/            <- manager chrome (system theme)
        templates/
          registries/
            llms.txt.tt
            sitemap.xml.tt
            feed.rss.tt
            feed.atom.tt
        auth/
          users               <- built-in auth users
          groups              <- built-in auth groups
        forms/
          handlers.conf       <- named dispatch handlers
          smtp.conf           <- SMTP connection settings
      assets/
        css/
        img/
        js/
      cgi-bin/
        lazysite-processor.pl
        lazysite-auth.pl
        plugins/form-handler.pl
        plugins/form-smtp.pl
        lazysite-manager-api.pl
      404.md
      index.md

## Further reading

- [Authoring](/docs/authoring) - Markdown, front matter, TT variables
- [Configuration](/docs/configuration) - views, nav.conf, lazysite.conf, themes
- [Reference](/docs/reference) - front matter keys, variables, file locations
- [Development](/docs/development) - dev server, troubleshooting, build tools
- [API mode](/docs/api) - raw mode, JSON endpoints, query strings

## Licence

MIT

## AI assistance

lazysite was developed interactively with Claude (Anthropic). Architecture,
design decisions, security review, and deployment were directed by the author.
Claude assisted with code generation, documentation, and iterative refinement
throughout development.

[views]: https://github.com/OpenDigitalCC/lazysite-views
