---
title: Development
subtitle: Local development server, build tools, and troubleshooting.
register:
  - sitemap.xml
---

## Local development server

`tools/lazysite-server.pl` runs the full processor on a non-privileged port.
No Apache configuration required.

    perl tools/lazysite-server.pl

Options:

    --port PORT       Port to listen on (default: 8080)
    --docroot PATH    Document root (default: ../starter)
    --processor PATH  Processor path (default: ../lazysite-processor.pl)
    --cache           Respect cache files (default: always regenerate)
    --help            Show help

With no arguments, the server serves the `starter/` directory on port 8080.
To serve your own site:

    perl tools/lazysite-server.pl --docroot /path/to/public_html

The server always regenerates pages by default (equivalent to
`LAZYSITE_NOCACHE=1`) so edits are visible immediately without deleting
cache files.

## LAZYSITE_NOCACHE

Set `LAZYSITE_NOCACHE=1` to bypass the cache read path when running the
processor manually:

    LAZYSITE_NOCACHE=1 REDIRECT_URL=/about \
    DOCUMENT_ROOT=/path/to/public_html \
      perl cgi-bin/lazysite-processor.pl

This forces the page to regenerate on every run. Note that cache files are
still written - `LAZYSITE_NOCACHE` skips reading the cache but not writing it.

## Running the processor manually

The most direct way to diagnose a page error:

    REDIRECT_URL=/about \
    DOCUMENT_ROOT=/home/username/web/example.com/public_html \
      perl /home/username/web/example.com/cgi-bin/lazysite-processor.pl

Prints full HTML output or Perl errors to the terminal. Adjust
`REDIRECT_URL` to the failing page path.

Override the default `lazysite.conf` path for testing:

    LAZYSITE_CONF=/path/to/alt.conf \
    REDIRECT_URL=/page \
    DOCUMENT_ROOT=/path/to/public_html \
      perl cgi-bin/lazysite-processor.pl

Or via command-line argument:

    perl cgi-bin/lazysite-processor.pl --conf /path/to/alt.conf

## Static site generation

Pre-render all pages for static hosting:

    # Build in-place
    bash tools/build-static.sh https://example.com

    # Build to a separate output directory
    bash tools/build-static.sh https://example.com ./dist

Deploy the output to GitHub Pages, Netlify, Cloudflare Pages, or any
plain web server.

## Link audit

`plugins/audit.pl` scans the docroot and reports orphaned pages
(source files with no inbound links) and broken links:

    perl plugins/audit.pl /home/username/web/example.com/public_html

Pass `--exclude` to omit specific pages from the orphan report:

    perl plugins/audit.pl --exclude changelog,contributing /path/to/docroot

## Cache management

Local `.md` pages regenerate automatically when the `.md` file is newer
than the cached `.html`. Editing and saving is sufficient - no manual step
needed.

Remote `.url` pages use TTL-based invalidation (default 1 hour). The stale
cache is served immediately; the refetch happens after TTL expiry.

To force regeneration:

    rm public_html/about.html
    find public_html -name "*.html" -delete

Index pages (`index.md` / `index.html`) are served directly by the web
server via `DirectoryIndex` and bypass the processor when the cache exists.
After editing `index.md`, delete the cached file manually:

    rm public_html/index.html

### Cache housekeeping

Content type sidecar files (`.ct`) in `lazysite/cache/ct/` are
managed automatically - created when a page is cached, deleted when
the corresponding `.html` is deleted.

To clear all cached state manually:

    find public_html/lazysite/cache -delete
    mkdir -p public_html/lazysite/cache

This removes both the layout cache and content type cache.

## Troubleshooting

### Check the error log

    tail -50 /home/username/web/example.com/logs/example.com.error.log

`End of script output before headers`
: The script crashed before printing anything. Run the processor manually
  to see the Perl error.

`lazysite: Cannot write cache file ... Fix with: chmod g+ws`
: The web server cannot write the generated `.html` to the docroot. Pages
  render correctly but are not cached. Fix with:

    chown ispadmin:www-data /home/username/web/example.com/public_html
    chmod g+ws /home/username/web/example.com/public_html

### Index page serves blank or stale content

Apache serves `index.html` directly via `DirectoryIndex`, bypassing the
processor. After editing `index.md`, delete the cache:

    rm public_html/index.html

### A page caches as an empty file

Usually caused by a layout template error. The processor falls back to
minimal HTML rather than crashing, but check the error log for layout
warnings. Delete the empty `.html` file to force regeneration after
fixing the template.

### Registries not generating

Registries only generate when a page is rendered - not on cached serves.
If missing, delete the registry file and force a page render:

    rm public_html/llms.txt
    rm public_html/index.html
    curl -s https://example.com/ > /dev/null

### Syntax check the processor

    perl -c cgi-bin/lazysite-processor.pl

## Logging

Log level and format are set in `lazysite.conf`:

    log_level: INFO    # ERROR, WARN, INFO, DEBUG
    log_format: text   # text or json

Override at startup with environment variables:

    LAZYSITE_LOG_LEVEL=DEBUG perl tools/lazysite-server.pl ...
    LAZYSITE_LOG_FORMAT=json perl tools/lazysite-server.pl ...

Each script declares a `$LOG_COMPONENT` identifier and calls
`log_event($level, $context, $message, %extra)`. Logs go to
`lazysite/logs/COMPONENT.log` when that directory is writable,
otherwise stderr.

## Rsync deployment

Standard command for syncing local development to a deployed site
while preserving runtime state:

```bash
rsync -av --delete \
    --exclude='.git' \
    --exclude='test-site' \
    --exclude='starter/lazysite/auth/' \
    --exclude='starter/lazysite/forms/contact.conf' \
    --exclude='starter/lazysite/forms/handlers.conf' \
    --exclude='starter/lazysite/forms/smtp.conf' \
    --exclude='starter/lazysite/lazysite.conf' \
    --exclude='starter/lazysite/nav.conf' \
    --exclude='starter/lazysite/cache/' \
    --exclude='starter/lazysite/logs/' \
    /home/user/lazysite/ /srv/projects/lazysite/
```

Runtime state files (user credentials, form config, site config, nav,
cache, logs) are excluded so local site data survives the sync.

## TTL and browser caching

Pages with `ttl:` set in front matter use
`Cache-Control: public, max-age=N`. When combined with `Vary: Cookie`
(sent on all responses), proxy caches will create separate entries per
cookie value. For public pages with `ttl:`, this is generally fine
since anonymous visitors share the same cache entry. For pages visible
to both authenticated and anonymous users, consider whether TTL caching
is appropriate.
