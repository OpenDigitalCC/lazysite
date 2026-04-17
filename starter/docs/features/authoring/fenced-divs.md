---
title: Fenced divs
subtitle: Wrap content in named CSS classes using ::: syntax.
tags:
  - authoring
---

## Fenced divs

The `:::` syntax wraps content in a `<div>` with a CSS class name.
Use it to create callouts, warnings, sidebars, or any styled block
without writing raw HTML.

### Syntax

    ::: classname
    Content here. Markdown is processed normally inside the block.
    :::

### Example

    ::: warning
    This operation cannot be undone. Back up your data first.
    :::

Renders as:

    <div class="warning">
    <p>This operation cannot be undone. Back up your data first.</p>
    </div>

### Class name validation

Class names must start with a word character and contain only word
characters (`a-z`, `A-Z`, `0-9`, `_`) and hyphens. Names that contain
other characters are rejected and the content is rendered without
a wrapper. Examples:

- `info` - valid
- `my-callout` - valid
- `alert_box` - valid
- `"inject` - rejected (contains quote)

### Notes

- `include` and `oembed` are reserved class names - they are handled
  by their dedicated converters and not converted to divs
- Fenced divs are processed before includes and code blocks in the
  pipeline, so Markdown inside a fenced div is converted normally
- Nesting fenced divs is not supported by the regex-based parser -
  the first `:::` closing line ends the outermost block
