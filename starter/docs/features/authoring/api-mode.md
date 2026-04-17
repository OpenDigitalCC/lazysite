---
title: API mode
subtitle: Output pure TT content with no Markdown conversion and no layout.
tags:
  - authoring
  - api
---

## API mode

Setting `api: true` in front matter treats the page body as pure
Template Toolkit content. No Markdown pipeline runs and no view
template is applied. The output is trimmed of leading and trailing
whitespace for clean JSON or other structured output.

### Syntax

    ---
    title: Status API
    api: true
    ---
    {"status": "ok", "site": "[% site_name %]"}

### Default content type

API mode serves `application/json; charset=utf-8` by default. Override
it with `content_type:`:

    ---
    api: true
    content_type: text/plain; charset=utf-8
    ---

### Example

    ---
    title: Pages API
    api: true
    tt_page_var:
      all_pages: scan:/blog/*.md sort=date desc
    ---
    [{"title": "[% p.title %]", "url": "[% p.url %]"}
    [% UNLESS loop.last %],[% END %]
    [% END %]

### Notes

- No Markdown conversion, no fenced divs, no includes, no oEmbed -
  the body is processed only by Template Toolkit
- Output is trimmed (`s/^\s+|\s+$//g`) for clean structured output
- TT variables from `lazysite.conf` and `tt_page_var` are available
- The content type is cached in `lazysite/cache/ct/`
- Pages with query parameters are not cached - query responses are
  rendered dynamically each request
- [Raw mode](/docs/features/authoring/raw-mode) - for Markdown-converted
  output without a layout
