# lazysite

Markdown-driven static pages for any CGI-capable web server. No build step,
no database, no CMS.

Drop a `.md` file in your docroot and it is served as a fully rendered HTML
page. The first request generates the HTML and caches it. Every subsequent
request is a plain static file.

## Documentation

Full documentation is in `starter/docs/` and is browseable locally:

    perl tools/lazysite-server.pl

Then open http://localhost:8080/ — the starter site includes:

- `/docs/README` — installation, configuration, and reference
- `/docs/authoring` — writing pages, Markdown, Template Toolkit variables
- `/docs/configuration` — views, nav.conf, lazysite.conf, themes
- `/docs/development` — dev server, troubleshooting, build tools
- `/docs/api` — raw mode, API mode, query strings
- `/lazysite-demo` — live feature demonstrator

Or read the docs directly in `starter/docs/`.

## Quick start

    git clone https://github.com/OpenDigitalCC/lazysite.git
    cd lazysite
    perl tools/lazysite-server.pl

Open http://localhost:8080/ to browse the starter site with the built-in
fallback view. Install a view from [lazysite-views][views] for a styled result.

## Installing on a server

    sudo bash install.sh --docroot /path/to/public_html \
                         --cgibin /path/to/cgi-bin \
                         --domain example.com

HestiaCP users: see `installers/hestia/`.

## Views

lazysite includes a built-in fallback view so it works without any
configuration files. For a styled site, install a view from
[lazysite-views][views]:

    curl -o public_html/lazysite/templates/view.tt \
      https://raw.githubusercontent.com/OpenDigitalCC/lazysite-views/main/default/view.tt

## Repository structure

    lazysite-processor.pl   <- the processor (single Perl script)
    install.sh              <- generic installer
    installers/hestia/      <- HestiaCP template and installer
    starter/                <- deployable starter site
      docs/                 <- documentation (browseable via dev server)
    tools/
      lazysite-server.pl    <- local development server
      build-static.sh       <- static site generator
      lazysite-audit.pl     <- link audit utility
    website/                <- lazysite.io site (.url files)

## Licence

MIT. See [LICENSE](LICENSE).

[views]: https://github.com/OpenDigitalCC/lazysite-views
