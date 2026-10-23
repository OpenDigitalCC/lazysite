---
title: Remote layouts
subtitle: Load a layout template from a remote URL with local caching.
tags:
  - configuration
  - template
  - remote
  - caching
---

## Remote layouts

Set `layout:` in `lazysite.conf` (or in front matter for a single
page) to a remote URL to fetch and cache a layout template from
any HTTP server. Remote layouts are the one exception to the
local layout/theme separation described in
[Layouts](/docs/features/configuration/layouts) and
[Themes](/docs/features/configuration/themes) - see
"Flat asset structure" below.

### Syntax

In `lazysite.conf`:

    layout: https://example.com/layouts/clean/layout.tt

Or per-page in front matter:

    ---
    layout: https://example.com/layouts/clean/layout.tt
    ---

### Caching

Remote layouts are cached in `lazysite/cache/layouts/` with a
filename derived from the URL (non-alphanumeric characters
replaced with `_`, truncated to 200 characters). The cache TTL
is 3600 seconds (1 hour), same as remote pages.

If a fetch fails, the stale cache is served if available. If no
cache exists and the fetch fails, the built-in fallback template
is used.

### Sandbox restrictions

Remote layout templates are processed with additional restrictions:

- `EVAL_PERL => 0` - no embedded Perl code execution
- `RELATIVE => 0` - no relative file includes

Local layouts do not have these restrictions.

### Flat asset structure

**Remote layouts keep the pre-D013 flat asset path.** A
`theme.json` manifest in the same directory as the remote
layout.tt triggers auto-fetch of the files listed in its
`files[]` array. Those assets land under
`/lazysite-assets/CACHE_KEY/` (not nested under a
LAYOUT/THEME tuple). The `theme_assets` TT variable
resolves to the same path.

This is deliberate. Remote layouts are distributed as single
packages - layout + bundled assets + design tokens in one URL.
The local theme/theme-per-layout separation assumes an
operator installs layouts and themes separately; the remote
model assumes they're shipped together. Treating remote as one
unit keeps the bundling simple and avoids designing a remote
theme distribution model.

The local `theme.config` auto-CSS-variable pipeline does not
apply to remote layouts - there's no local `theme.json` driving
it, so `[% theme_css %]` is empty. Remote layouts bundle their
own stylesheets and set their own defaults.

### Example

    layout: https://raw.githubusercontent.com/OpenDigitalCC/lazysite-layouts/main/default/layout.tt

### Notes

- Remote URLs must start with `http://` or `https://`
- `theme_assets` is `/lazysite-assets/CACHE_KEY/` for remote
  (flat), `/lazysite-assets/LAYOUT/THEME/` for local (nested)
- Future candidate: a proper remote theme distribution model so
  multiple themes can target a single remote layout. Not in 0.3.0.
- [Layouts](/docs/features/configuration/layouts) -
  local layout resolution
- [Themes](/docs/features/configuration/themes) -
  local theme resolution
