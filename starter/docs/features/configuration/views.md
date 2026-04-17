---
title: Views
subtitle: Control site visual presentation with a Template Toolkit view template.
tags:
  - configuration
  - template
---

## Views

A view is a Template Toolkit file (`view.tt`) that wraps rendered page
content. It controls the HTML structure, styling, and layout of every
page on the site.

### Location

    public_html/lazysite/templates/view.tt

### Fallback chain

When rendering a page, lazysite looks for a view template in this order:

1. Per-page `layout:` front matter value (checked as theme, then
   named template)
2. Site-wide `theme:` from `lazysite.conf` (checked as theme, then
   named template)
3. Default `lazysite/templates/view.tt`
4. Built-in fallback (minimal HTML with inline CSS)

The built-in fallback ensures pages always render, even without any
configuration.

### Available TT variables

All variables from `lazysite.conf`, plus:

- `content` - the rendered page body HTML
- `page_title` - from front matter `title:`
- `page_subtitle` - from front matter `subtitle:`
- `page_modified` - formatted mtime ("1 January 2024")
- `page_modified_iso` - ISO mtime ("2024-01-01")
- `nav` - navigation array from `nav.conf`
- `theme_assets` - asset path for remote themes (when applicable)

### Example

    <!DOCTYPE html>
    <html lang="en">
    <head>
      <title>[% page_title %] - [% site_name %]</title>
    </head>
    <body>
      <h1>[% page_title %]</h1>
      [% content %]
    </body>
    </html>

### Notes

- Delete all `.html` cache files after changing the view template to
  see the new layout on all pages
- The view template has full TT capabilities including `INCLUDE`,
  `PROCESS`, conditionals, and loops
- The built-in fallback displays a footer noting that no view.tt was
  found
- [Themes](/docs/features/configuration/themes) - named themes in the
  themes directory
