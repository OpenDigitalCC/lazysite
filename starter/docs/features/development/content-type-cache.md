---
title: Content type cache
subtitle: How lazysite caches content types for raw and api mode pages.
tags:
  - development
  - caching
  - api
---

## Content type cache

Pages with non-default content types (raw mode, api mode, or custom
`content_type:`) store the content type in a sidecar cache file so
that cache hits can serve the correct `Content-type` header without
re-reading the source.

### Storage location

    public_html/lazysite/cache/ct/

### Filename format

Path separators are replaced with colons. For example, `api/status`
becomes `api:status.ct`. The file contains only the content type
string.

### When written

A `.ct` file is written when the page's content type is not the
default `text/html; charset=utf-8`. This applies to:

- `api: true` pages (default: `application/json; charset=utf-8`)
- `raw: true` pages (default: `text/plain; charset=utf-8`)
- Pages with explicit `content_type:` in front matter

### When read

On cache hits (the fast path in `main()`), the `.ct` file is read
to determine the correct `Content-type` header. If no `.ct` file
exists, the default `text/html; charset=utf-8` is used.

### Cleanup

When a page is rendered and its content type is the default (or
undefined), any existing `.ct` file for that path is deleted. This
handles the case where a page changes from `api: true` back to
normal mode.

### Example

    $ cat public_html/lazysite/cache/ct/api:status.ct
    application/json; charset=utf-8

### Notes

- Normal HTML pages never write a `.ct` file
- The cache directory is created automatically on first write
- To clear all content type cache entries:
  `rm -rf public_html/lazysite/cache/ct/`
- [API mode](/docs/features/authoring/api-mode) - pages that use
  non-default content types
- [Raw mode](/docs/features/authoring/raw-mode) - another mode with
  custom content types
