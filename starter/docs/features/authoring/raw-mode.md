---
title: Raw mode
subtitle: Output converted content without the view template wrapper.
tags:
  - authoring
  - api
---

## Raw mode

Setting `raw: true` in front matter outputs the processed content body
without wrapping it in the view template. The full Markdown pipeline
runs (fenced divs, includes, code blocks, oEmbed, Markdown conversion)
and TT variables are resolved, but no layout is applied.

### Syntax

    ---
    title: My Widget
    raw: true
    ---
    <div id="widget">[% site_name %]</div>

### Default content type

Raw mode serves `text/plain; charset=utf-8` by default. Override it
with the `content_type:` front matter key for a non-HTML artifact:

    ---
    raw: true
    content_type: text/csv; charset=utf-8
    ---

### Example

    ---
    title: Sensor Feed
    raw: true
    content_type: application/json; charset=utf-8
    ---
    { "temperature": [% temperature %], "unit": "C" }

### HTML/SVG content types are not permitted in raw mode

A raw page is served **verbatim**, with no layout and no output
escaping. A script-capable content type (`text/html`,
`application/xhtml+xml`, `image/svg+xml`) on a raw page would therefore
let page content run script in every visitor's browser - a stored
cross-site-scripting vector, especially where a delegated editor may
write content but not layouts. Raw mode enforces this mechanically: if a
raw page declares one of those types it is **downgraded to
`text/plain`** at serve time (and the attempt is logged). To publish:

- **HTML** - author an ordinary page and let it render through a layout,
  which escapes content correctly; or place a static `.html` file in the
  document tree and let the web server serve it.
- **SVG or another binary/markup asset** - store it as a real static
  file (`.svg`, `.pdf`, ...) served by the web server, not generated
  through raw mode.

Raw mode is for **data** artifacts (JSON, CSV, XML, plain text) whose
values you want templated from site variables.

### Notes

- The Markdown pipeline runs: fenced divs, includes, code blocks,
  oEmbed, and Markdown-to-HTML conversion all apply
- TT variables from `lazysite.conf` and `tt_page_var` are available
- The content type is cached in `lazysite/cache/ct/` so subsequent
  cache hits serve the correct header
- The page is cached the same as normal pages
- [API mode](/docs/features/authoring/api-mode) - for pure TT output
  with no Markdown conversion
