---
title: Remote pages
subtitle: Serve Markdown content fetched from a remote URL via .url files.
tags:
  - authoring
  - remote
  - caching
---

## Remote pages

Drop a `.url` file containing a single URL to serve remote Markdown
content as a local page. The remote content is fetched, processed
through the full pipeline, and cached locally.

### Syntax

Create a file with a `.url` extension containing the remote URL:

    https://raw.githubusercontent.com/owner/repo/main/README.md

The file contains only the URL, trimmed of whitespace.

### Cache and TTL

Remote pages are cached as `.html` files, same as local pages. The
cache TTL is 3600 seconds (1 hour) by default. The page is re-fetched
when the cache expires.

If a fetch fails, the stale cache is served if available. If no cache
exists and the fetch fails, an error page is rendered with the class
`errorbox`.

### Pipeline

The fetched content is processed through the full pipeline:
fenced divs, includes, code blocks, oEmbed, Markdown conversion,
TT variable resolution, and view template wrapping. The remote
content can use front matter for title, subtitle, and other metadata.

### Example

    $ cat public_html/changelog.url
    https://raw.githubusercontent.com/owner/repo/main/CHANGELOG.md

Visiting `/changelog` fetches and renders the remote Markdown file.

### Notes

- Only `http://` and `https://` URLs are accepted
- The `.url` file itself is never served - only the rendered content
- `.url` files support `raw: true` in the fetched content's front
  matter for layout-less output
- The fetch uses a 10-second timeout with user agent `lazysite/1.0`
- `.url` files are checked after `.md` files - if both exist for the
  same path, the `.md` file takes priority
- [Content includes](/docs/features/authoring/includes) - for inlining
  remote content within a page
