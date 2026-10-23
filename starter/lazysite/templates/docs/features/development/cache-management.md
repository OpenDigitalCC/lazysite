---
title: Cache management
subtitle: How lazysite caches pages and how to control regeneration.
tags:
  - development
  - caching
---

## Cache management

lazysite caches rendered pages as `.html` files alongside their `.md`
sources. The cache is transparent - Apache's `DirectoryIndex` serves
the `.html` file directly without invoking the processor.

### When cache is served

A cached `.html` file is served when:

- The `.html` file exists and its mtime is newer than the `.md` source
- OR the page has a `ttl:` in front matter and the cache age is within
  the TTL (even if the `.md` file is newer)

Cache is skipped when:

- `LAZYSITE_NOCACHE` is set
- The request has active query parameters (declared in `query_params:`)

### When cache is written

After processing a page, the rendered HTML is written to the
corresponding `.html` path. Cache writes are skipped when:

- `LAZYSITE_NOCACHE` is set
- The page has active query parameters
- The rendered content is zero bytes (safety guard)
- The output path resolves outside the docroot (symlink protection)

### Forcing regeneration

Delete the cached `.html` file:

    rm public_html/my-page.html

The next request to `/my-page` regenerates and caches it.

Clear all cached pages:

    find public_html -name "*.html" ! -path "*/lazysite/*" -delete

### Page TTL

Set `ttl:` in front matter to keep serving the cache even when the
`.md` source is newer:

    ---
    ttl: 300
    ---

The TTL is in seconds. This is useful for pages with `url:` or `scan:`
variables that should not regenerate on every source file touch.

### Browser caching

When a page has `ttl:` set, the processor sends a
`Cache-Control: public, max-age=TTL` HTTP header. This tells the
browser to cache the response for that duration without revalidating.

Pages without `ttl:` do not send a `Cache-Control` header - browser
behaviour depends on its defaults.

When `LAZYSITE_NOCACHE` is set, the `Cache-Control` header is still
sent if the page has `ttl:` - NOCACHE only affects the server-side
`.html` cache, not browser cache headers.

### Notes

- The `.html` file must have the same name as the `.md` file (e.g.,
  `about.md` caches to `about.html`)
- Zero-byte `.html` files are never written - this prevents empty
  cache files from blocking regeneration via `DirectoryIndex`
- New directories created for cache files inherit the docroot's group
  ownership with the setgid bit set
- [LAZYSITE_NOCACHE](/docs/features/development/nocache) - bypass
  caching entirely
- [Content type cache](/docs/features/development/content-type-cache) -
  separate cache for content type headers
