---
title: Per-page layout override
subtitle: Use a different layout for a specific page via front matter.
tags:
  - configuration
  - template
  - authoring
---

## Per-page layout override

Set `layout:` in a page's front matter to render that page through a
different layout. This overrides the site's `layout:` setting in
`lazysite.conf` (or the domain's, on a multi-domain site).

### Syntax

    ---
    title: Landing Page
    layout: landing
    ---

### Resolution

The `layout:` value resolves the way the site-wide one does:

1. `lazysite/layouts/NAME/layout.tt` - an installed layout
2. If that file does not exist, a warning is logged and the page renders
   through the built-in fallback template - not through the site's own
   layout

The name is sanitised to `a-z`, `A-Z`, `0-9`, `_`, `-` only.

### Remote layouts

The `layout:` value can be a remote URL:

    ---
    layout: https://example.com/layouts/special/layout.tt
    ---

Remote layouts are cached and sandboxed the same as a site-wide remote
layout. See [Remote layouts](/docs/features/configuration/remote-layouts).

### Example

Create a minimal layout for a specific page:

    # lazysite/layouts/bare/layout.tt
    [% content %]

Use it in the page:

    ---
    title: Embed Widget
    layout: bare
    ---
    <div id="widget">Widget content</div>

### Notes

- A page's `layout:` takes precedence over the site's `layout:`
- A page can also pin a theme with `theme:`; it applies when the theme
  is compatible with the layout the page renders through
- [Layouts](/docs/features/configuration/layouts) - the layout reference
  and the variables a `layout.tt` receives
- [Themes](/docs/features/configuration/themes) - themes and how one is
  chosen
