---
title: Per-page layout override
subtitle: Use a different view template for a specific page via front matter.
tags:
  - configuration
  - template
  - authoring
---

## Per-page layout override

Set `layout:` in a page's front matter to use a different view template
for that page. This overrides the site-wide `theme:` setting from
`lazysite.conf`.

### Syntax

    ---
    title: Landing Page
    layout: landing
    ---

### Resolution

The `layout:` value follows the same resolution as `theme:`:

1. `lazysite/themes/NAME/view.tt` - theme directory
2. `lazysite/templates/NAME.tt` - named template file
3. Falls back to default `view.tt` if not found

The name is sanitised to `a-z`, `A-Z`, `0-9`, `_`, `-` only.

### Remote layouts

The `layout:` value can be a remote URL:

    ---
    layout: https://example.com/themes/special/view.tt
    ---

Remote layouts are cached and sandboxed the same as site-wide remote
themes.

### Example

Create a minimal template for a specific page:

    # lazysite/templates/bare.tt
    [% content %]

Use it in the page:

    ---
    title: Embed Widget
    layout: bare
    ---
    <div id="widget">Widget content</div>

### Notes

- `layout:` takes precedence over `theme:` in `lazysite.conf`
- If the named layout is not found, a warning is logged and the
  default `view.tt` is used
- [Themes](/docs/features/configuration/themes) - site-wide theme
  configuration
- [Views](/docs/features/configuration/views) - view template
  reference
