---
title: Installation
subtitle: Requirements, server setup, and getting started.
register:
  - sitemap.xml
---

## Why lazysite

Drop `.md` files in your docroot and they are served as fully rendered
HTML pages - no build step, no CMS, no database. Pages are generated on
first request and cached as static HTML. Content is portable, version
control friendly, and works with any deployment workflow.

For the full motivation behind lazysite, see [Motivation](https://lazysite.io/motivation).

## Web server support

lazysite runs on its own built-in server, or on any standard web server via
CGI and error-handler mechanisms.

- Built-in server - `perl tools/lazysite-server.pl` runs the full processor on a non-privileged port with no configuration; ideal for development, previews, and small internal or home use
- Apache 2.4 - supported, HestiaCP installer provided
- Apache without HestiaCP - configure `FallbackResource` manually
- Nginx - use `error_page 403 404` to point to the CGI script
- Any web server with CGI support and configurable error handlers should work

If you use a front end other than the shipped Apache, nginx or built-in server
**and you intend to protect static files with ACLs**, read *Your web server has
to co-operate* in [Authentication](/docs/auth). A web server that answers an
existing file from disk never reaches lazysite, so a per-file access rule cannot
apply - and the failure is silent. Sites that do not use ACLs are unaffected and
need nothing.

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

### You install the package; you provision a site

Two different acts, and lazysite keeps them apart on purpose:

| Act | What it touches |
| --- | --- |
| **Installing lazysite** on a host | the engine payload and the `lazysite` command. No site tree is touched. |
| **Provisioning a site** | one domain's docroot and `cgi-bin`. |

So a host with lazysite installed and no sites provisioned is a normal state,
and installing a newer lazysite never changes a site by itself.

### The site commands

Three verbs, and **you say which one you mean.** None of them works out your
intention from the state of the disk, and each refuses rather than quietly
doing one of the others:

```bash
lazysite provision --docroot /path/to/public_html --cgibin /path/to/cgi-bin
lazysite upgrade   --docroot /path/to/public_html
lazysite reinstall --docroot /path/to/public_html
```

| Verb | Use it when | It refuses when |
| --- | --- | --- |
| `provision` | the site does not exist yet | something is already installed there |
| `upgrade` | the site should move to this version | nothing is installed, or the site is already at this version |
| `reinstall` | this version's files were edited or lost and should go back to what the release ships | the versions differ — that is an upgrade |

`reinstall` leaves content, accounts and configuration alone. It is not
[`repair`](#if-something-is-wrong-and-the-version-is-not-changing), which
touches no files at all.

Run them as the **site's own user**, never with `sudo`: they refuse root, so
that nothing in a site tree ends up owned by root. Each verb reads
`release-manifest.json` from the payload and records what it installed at
`{docroot}/lazysite/.install-state.json`.

### From an unpacked tarball

There is no `lazysite` on `PATH` until the package is installed, so run the
command out of the tree you unpacked. It finds its own payload:

```bash
tar xf lazysite-<version>.tar.gz
cd lazysite-<version>
perl tools/lazysite-cli.pl provision \
    --docroot /path/to/public_html --cgibin /path/to/cgi-bin
```

The verbs and their options are identical. A tarball is how the code reaches
the host; it is not a different way to install a site. A refusal from any
verb spells the command it recommends the way you reached it — `perl
tools/lazysite-cli.pl …` here, `lazysite …` once the package is installed.

`upgrade` and `reinstall` take the cgi-bin from the site's registry entry
(`/etc/lazysite/sites.d/`, written by `provision`). A site with no entry —
one provisioned before the registry existed, or on a host where that
directory was not writable — needs `--cgibin` as well, and the verb says so
rather than guessing:

```bash
perl tools/lazysite-cli.pl upgrade \
    --docroot /path/to/public_html --cgibin /path/to/cgi-bin
```

On a HestiaCP host the pair is always `DIR/public_html` and `DIR/cgi-bin`
under `/home/<user>/web/<domain>`, so all three verbs also take
`--installdir DIR` in place of both:

```bash
perl tools/lazysite-cli.pl upgrade --installdir /home/<user>/web/<domain>
```

`install.sh` in the tarball root installs nothing. It is kept only to point
anyone who still types it at the three verbs above.

### HestiaCP

lazysite registers itself as a HestiaCP web template, so a domain is set up
from the control panel and the engine is deployed on rebuild. Install the
`lazysite-common` and `lazysite-hestia` packages, copy the templates into
Hestia's template directories, then per domain:

1. Edit your domain
2. Set the web template to `lazysite-cgi` (or `lazysite-fcgi`)
3. Save and rebuild

The full sequence, including the nginx proxy layer and the per-domain
onboarding command, is in `installers/hestia/INSTALL-RUNBOOK.md` in the
release.

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
mkdir -p /var/www/example.com/public_html/lazysite/layouts
mkdir -p /var/www/example.com/public_html/lazysite-assets
cp starter/lazysite.conf.example   /var/www/example.com/public_html/lazysite/lazysite.conf
cp starter/lazysite/templates/registries/*.tt  /var/www/example.com/public_html/lazysite/templates/registries/
mkdir -p /var/www/example.com/public_html/lazysite/templates/system
cp starter/lazysite/templates/system/*.md  /var/www/example.com/public_html/lazysite/templates/system/
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

1. Install a layout from
   [lazysite-layouts][layouts] or write your own `layout.tt`
2. Install a compatible theme (manager UI or zip upload) and set
   `layout:` and `theme:` in `lazysite.conf`
3. Edit `public_html/lazysite/nav.conf` to define your site navigation
4. Edit `public_html/index.md` for your home page content
5. Add pages by dropping `.md` files anywhere in the docroot

Pages are available immediately at their extensionless URL:

    public_html/about.md            -> https://example.com/about
    public_html/services/hosting.md -> https://example.com/services/hosting
    public_html/services/index.md   -> https://example.com/services/

Directory index pages are served when a trailing slash URL is requested.
Create `dirname/index.md` for any directory that needs an index page.

### Using an AI assistant

Four audience-specific briefings live under `starter/docs/`:

- `ai-briefing-authoring.md` - writing content
- `ai-briefing-layouts.md` - designing layouts and themes
- `ai-briefing-configuration.md` - configuring a site
- `ai-briefing-development.md` - working on the codebase

Feed the relevant briefing to an AI assistant at the start of a
session to enable help without needing to explain the system each
time. In Claude Projects, save it as a project document. For other
AI tools, paste it as context at the start of the conversation.

## Upgrading

Install the newer lazysite on the host, then move each site to it:

```bash
lazysite upgrade --docroot /path/to/public_html
```

Seed files you have edited (starter pages, docs) are preserved; code files
(processor, extensions, manager UI) are always refreshed. Run it as the site's
user — it refuses root.

Inspect the plan before committing to it:

```bash
lazysite upgrade --docroot /path/to/public_html --dry-run
```

`--dry-run` reports what would change and writes nothing at all. It is a
single-site preview and does not combine with `--all`.

Before applying an upgrade — or a reinstall — lazysite writes a backup tarball
to `{docroot}/lazysite/backups/`. `backup_retention` in `lazysite.conf`
controls how many are kept (default 3; 0 = keep all).

### A whole host at once

```bash
sudo lazysite upgrade --all
```

As root this drops to each site's own user, so no site tree is written as root.
Sites whose `update_policy` is `manual` (the default) are skipped unless
`--force` is given, and each site's `update_channel` is then honoured — see
[Update channel](/docs/features/configuration/update-channel).

### After an upgrade, restart anything that holds engine code

An ordinary CGI site reads the engine fresh on every request and needs nothing.
A site running the persistent runtime or the FastCGI pool has the previous
engine in memory and goes on serving it until the worker restarts. `upgrade`
and `reinstall` name the units to restart when there are any; `upgrade --all`,
which runs as root, restarts them itself.

### If something is wrong and the version is not changing

Two different problems, two different commands:

| Symptom | Command |
| --- | --- |
| engine files were edited or lost; put the shipped ones back | `lazysite reinstall --docroot D` |
| the files are right but ownership, modes or missing directories are not | `lazysite repair --docroot D` |

`repair` changes no files; `reinstall` replaces them and leaves content,
accounts and configuration alone.

### If an upgrade goes wrong

List the backups:

```bash
lazysite backups --docroot /path/to/public_html
```

Put the most recent one back:

```bash
lazysite backups --docroot /path/to/public_html --restore
```

Or a specific one:

```bash
lazysite backups --docroot /path/to/public_html --restore \
    --backup /path/to/backup.tar.gz
```

Restoring does not touch runtime state (auth users, cache, logs) and
invalidates the rendered HTML cache afterwards.

## Uninstall

There is no uninstall script. Removal is manual, and deliberately so - the
installer only ever adds files to a domain's `cgi-bin/` and the Hestia template
directory, so there is nothing to unwind beyond deleting them.

To remove lazysite from one domain, delete the engine scripts the installer
placed in that domain's `cgi-bin/` (`lazysite-processor.pl`, `lazysite-auth.pl`
and the other `lazysite-*.pl` entry points) and restore the web-server
configuration that was in place before.

**A domain's content is not touched by any of this.** The `public_html` tree -
pages, `lazysite/`, uploads - is yours and stays exactly where it is. Back it up
before removing anything if you intend to move it elsewhere.

## File reference

    public_html/
      lazysite/
        lazysite.conf         <- site configuration
        nav.conf              <- navigation (YAML)
        layouts/
          LAYOUT/
            layout.tt         <- layout template
            layout.json       <- layout metadata (optional)
            themes/
              THEME/
                theme.json    <- theme manifest
                main.css      <- theme stylesheet
                assets/       <- theme assets
        manager/              <- manager chrome (internal; D013)
          layout.tt
          assets/manager.css
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
          handlers.conf       <- the handlers a form or the schedule calls
          schedule.conf       <- what the timer calls
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

[layouts]: https://github.com/OpenDigitalCC/lazysite-layouts
