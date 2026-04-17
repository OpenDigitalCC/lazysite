---
title: Include TTL
subtitle: Set parent page cache TTL from an include block.
tags:
  - authoring
  - remote
  - caching
---

## Include TTL

The `ttl=N` modifier on a `:::include` block sets the parent page's
cache TTL in seconds. This is useful when a page includes remote content
that should be refreshed periodically without setting `ttl:` in every
page's front matter.

### Syntax

    ::: include ttl=300
    https://example.com/feed.md
    :::

### Behaviour

The modifier sets `$meta->{ttl}` only when the page does not already
have a `ttl:` key in its front matter. If front matter defines `ttl:`,
the modifier is ignored. This means front matter always takes priority.

If multiple `:::include` blocks specify `ttl=N`, the first one wins -
subsequent modifiers do not overwrite a TTL that is already set.

### Example

    ---
    title: Dashboard
    ---
    ::: include ttl=120
    https://example.com/status.md
    :::

The page cache refreshes every 120 seconds. If the front matter had
`ttl: 60`, the modifier would be ignored and the 60-second TTL would
apply.

### Notes

- The TTL only affects the parent page's cache lifetime, not the
  included content itself
- Without a TTL, pages are cached indefinitely until the source `.md`
  file is modified
- The TTL value is in seconds
- [Content includes](/docs/features/authoring/includes) - full include syntax reference
