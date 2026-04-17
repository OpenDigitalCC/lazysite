---
title: Remote layouts
subtitle: Load a view template from a remote URL with local caching.
tags:
  - configuration
  - template
  - remote
  - caching
---

## Remote layouts

Set `theme:` in `lazysite.conf` or `layout:` in front matter to a
remote URL to fetch and cache a view template from any HTTP server.

### Syntax

In `lazysite.conf`:

    theme: https://example.com/themes/clean/view.tt

Or per-page in front matter:

    ---
    layout: https://example.com/themes/clean/view.tt
    ---

### Caching

Remote layouts are cached in `lazysite/cache/layouts/` with a filename
derived from the URL (non-alphanumeric characters replaced with `_`,
truncated to 200 characters). The cache TTL is 3600 seconds (1 hour),
same as remote pages.

If a fetch fails, the stale cache is served if available. If no cache
exists and the fetch fails, the built-in fallback template is used.

### Sandbox restrictions

Remote layout templates are processed with additional restrictions:

- `EVAL_PERL => 0` - no embedded Perl code execution
- `RELATIVE => 0` - no relative file includes

Local layout templates do not have these restrictions.

### Example

    theme: https://raw.githubusercontent.com/OpenDigitalCC/lazysite-views/main/default/view.tt

### Notes

- Remote URLs must start with `http://` or `https://`
- A `theme.json` manifest in the same directory triggers automatic
  asset fetching - see [theme.json](/docs/features/configuration/theme-json)
- The `theme_assets` TT variable is set to `/lazysite-assets/CACHE_KEY`
  for remote themes, allowing asset references in the template
- [Themes](/docs/features/configuration/themes) - local theme resolution
