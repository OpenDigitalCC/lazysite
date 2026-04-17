---
title: theme.json
subtitle: Declare theme assets for automatic fetching alongside a remote view.
tags:
  - configuration
  - template
  - remote
---

## theme.json

When a remote layout is fetched, lazysite looks for a `theme.json`
manifest in the same directory as the view template. If found, the
listed asset files are downloaded and stored locally.

### Location

The manifest URL is derived from the view template URL by replacing
the filename with `theme.json`. For a view at
`https://example.com/themes/clean/view.tt`, lazysite fetches
`https://example.com/themes/clean/theme.json`.

### Format

    {
      "files": [
        "style.css",
        "script.js",
        "images/logo.png"
      ]
    }

The `files` array lists relative paths to download. Only the `files`
field is used.

### Asset storage

Assets are written to:

    public_html/lazysite-assets/CACHE_KEY/

Where `CACHE_KEY` is derived from the view template URL (same key
used for the layout cache).

### TT variable

The `theme_assets` variable is set automatically for remote themes:

    <link rel="stylesheet" href="[% theme_assets %]/style.css">

This resolves to `/lazysite-assets/CACHE_KEY/style.css`.

### Example

    {
      "files": [
        "style.css",
        "fonts/inter.woff2",
        "images/favicon.ico"
      ]
    }

### Notes

- `view.tt` in the files list is skipped (already fetched separately)
- Paths containing `..` are skipped (traversal protection)
- Subdirectories in file paths are created automatically
- Assets are fetched at the same time as the layout and follow the
  same TTL
- If `theme.json` is not found or fails to parse, only the view
  template is used - no error is raised
- [Remote layouts](/docs/features/configuration/remote-layouts) -
  remote view template loading
