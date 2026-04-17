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
with the `content_type:` front matter key:

    ---
    raw: true
    content_type: text/html; charset=utf-8
    ---

### Example

    ---
    title: Embed Fragment
    raw: true
    content_type: text/html; charset=utf-8
    ---
    <section class="embed">

    ## Latest update

    Content is converted from Markdown to HTML.

    </section>

### Notes

- The Markdown pipeline runs: fenced divs, includes, code blocks,
  oEmbed, and Markdown-to-HTML conversion all apply
- TT variables from `lazysite.conf` and `tt_page_var` are available
- The content type is cached in `lazysite/cache/ct/` so subsequent
  cache hits serve the correct header
- The page is cached the same as normal pages
- [API mode](/docs/features/authoring/api-mode) - for pure TT output
  with no Markdown conversion
