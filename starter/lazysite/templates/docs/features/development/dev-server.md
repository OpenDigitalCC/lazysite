---
title: Development server
subtitle: Run lazysite locally without Apache using the built-in dev server.
tags:
  - development
---

## Development server

The built-in dev server runs lazysite locally for development and
testing. It invokes the processor for each request and serves static
assets directly. Not for production use.

### Invocation

    perl tools/lazysite-server.pl

Opens at `http://localhost:8080/` serving the `starter/` directory.

### Options

- `--port PORT` - port to listen on (default: 8080)
- `--docroot PATH` - document root (default: `../starter` relative to
  the script)
- `--processor PATH` - processor script path (default:
  `../lazysite-processor.pl` relative to the script)
- `--cache` - respect cache files (default: always regenerate)
- `--help` - show help

### Example

Serve your own site:

    perl tools/lazysite-server.pl --docroot /path/to/public_html

Serve on a different port with caching enabled:

    perl tools/lazysite-server.pl --port 3000 --cache

### Default behaviour

- Cache is disabled by default (`LAZYSITE_NOCACHE=1`) so every request
  regenerates the page - edit and refresh to see changes
- Static files (CSS, JS, images, fonts) are served directly without
  invoking the processor
- Files with `.md`, `.url`, `.tt`, and `.conf` extensions are never
  served as static files
- Cached `.html` files are skipped when a matching `.md` or `.url`
  source exists - the processor always handles these
- URL query strings are passed to the processor via `QUERY_STRING`
- All CGI response headers from the processor are forwarded to the
  browser (Status, Content-type, Cache-Control, etc.)
- Request timing is shown in the terminal when `Time::HiRes` is
  available

### Notes

- The server checks for required Perl modules on startup and warns
  about missing optional modules (e.g. JSON.Escape for search)
- Stderr from the processor is printed to the terminal for debugging
- The server listens on `0.0.0.0` (all interfaces)
- [LAZYSITE_NOCACHE](/docs/features/development/nocache) - cache bypass
  details
