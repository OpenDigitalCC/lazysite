---
title: 404 page
subtitle: Customise the not-found page with a standard Markdown file.
tags:
  - authoring
  - configuration
---

## 404 page

Create a `404.md` file in the docroot to customise the not-found page.
It is processed through the full pipeline including the view template,
giving it the same look as the rest of the site.

### Syntax

    ---
    title: Not Found
    ---
    The page you requested could not be found.

    [Return to the home page](/)

### Location

The file must be at the docroot root: `public_html/404.md`. It
generates `404.html` which is cached and served for subsequent 404
responses.

### Behaviour

When a request matches no `.md` or `.url` file, the processor:

1. Checks for `404.md` in the docroot
2. If found and `404.html` cache is fresh (mtime check), serves cache
3. If found but stale or no cache, processes through `process_md` with
   the full pipeline and view template, caches result
4. If `404.md` does not exist, returns a bare HTML fallback showing
   the requested path

The response always returns HTTP status `404 Not Found` regardless of
whether a custom page exists.

### Example

    ---
    title: Page not found
    subtitle: Sorry, that page doesn't exist.
    ---
    ## Nothing here

    The page you're looking for may have moved or been removed.

    Try the [home page](/) or use the navigation above.

### Notes

- The 404 page uses the same view template as all other pages
- TT variables from `lazysite.conf` are available
- Cache invalidation works the same as normal pages - edit `404.md`
  or delete `404.html` to regenerate
- The bare fallback (when no `404.md` exists) displays the requested
  URI in a `<code>` tag
