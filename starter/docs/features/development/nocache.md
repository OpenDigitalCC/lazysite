---
title: LAZYSITE_NOCACHE
subtitle: Bypass cache reads and writes for development and testing.
tags:
  - development
  - caching
---

## LAZYSITE_NOCACHE

Setting the `LAZYSITE_NOCACHE` environment variable bypasses both cache
reading and cache writing. Every request processes the page from source.

### What is bypassed

Cache reads: the fast path in `main()` that serves `.html` cache files
is skipped entirely. The processor always reads and processes the `.md`
source file.

Cache writes: `write_html()` returns immediately without writing the
`.html` cache file. No cache files are created or updated.

### How to set it

Environment variable:

    LAZYSITE_NOCACHE=1 perl cgi-bin/lazysite-processor.pl

The dev server sets it by default:

    perl tools/lazysite-server.pl

To disable it in the dev server (enable caching):

    perl tools/lazysite-server.pl --cache

### Example

Test a page without touching the cache:

    LAZYSITE_NOCACHE=1 \
    REDIRECT_URL=/my-page \
    DOCUMENT_ROOT=/path/to/public_html \
      perl cgi-bin/lazysite-processor.pl

### Notes

- Any truthy value works (`1`, `true`, `yes`, etc.) - the check is
  `$ENV{LAZYSITE_NOCACHE}` which is true for any non-empty string
- Query parameter cache bypass is separate - pages with active query
  params skip cache regardless of this setting
- Registry updates still run when NOCACHE is set (the cache bypass
  only affects the page's own `.html` file)
- [Development server](/docs/features/development/dev-server) - the
  dev server sets this by default
