---
title: Template Toolkit variables
subtitle: Use TT variables and logic in page content and the view template.
tags:
  - authoring
  - template
---

## Template Toolkit variables

Page content and view templates are processed by Template Toolkit (TT).
Variables come from three sources: site-wide configuration, per-page
definitions, and automatic page metadata.

### Variable sources

Site variables (from `lazysite.conf`):

    site_name: My Site
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
    footer_text: Copyright 2024

Per-page variables (from front matter `tt_page_var:`):

    ---
    tt_page_var:
      features: scan:/docs/features/*.md sort=title asc
      version: url:https://example.com/version.txt
      label: Custom Label
    ---

Automatic variables (always available):

- `page_title` - from front matter `title:`
- `page_subtitle` - from front matter `subtitle:`
- `page_modified` - file mtime formatted as "1 January 2024"
- `page_modified_iso` - file mtime as "2024-01-01"
- `content` - rendered page body (available in the view template)
- `nav` - navigation array from `nav.conf`
- `query` - query parameter hash (when `query_params:` is declared)

### Value types

Literal value:

    my_var: some text

Environment variable interpolation (allowlisted variables only):

    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

Allowlisted variables: `SERVER_NAME`, `SERVER_PORT`, `REQUEST_SCHEME`,
`HTTPS`, `REQUEST_URI`, `REDIRECT_URL`, `DOCUMENT_ROOT`, `SERVER_ADMIN`.

Remote URL fetch:

    latest: url:https://example.com/data.txt

Directory scan:

    posts: scan:/blog/*.md sort=date desc

### Example

    ---
    title: Dashboard
    tt_page_var:
      posts: scan:/blog/*.md sort=date desc
      motto: Live free or die
    ---
    ## [% motto %]

    [% FOREACH post IN posts %]
    - [[% post.title %]]([% post.url %]) ([% post.date %])
    [% END %]

### Notes

- Code blocks (`<pre><code>` and inline `<code>`) are protected from
  TT processing - TT directives inside code blocks are preserved as
  literal text
- TT directives in front matter scalar values (`title:`, `subtitle:`,
  etc.) are stripped for security - `[%` and `%]` sequences are removed
- The content TT pass uses `ABSOLUTE => 0` to prevent file access
  from within page content
- Site variables and page variables with the same name: page variables
  take precedence
- [lazysite.conf](/docs/features/configuration/lazysite-conf) - site
  variable configuration
