---
title: Content includes
subtitle: Inline local or remote content directly into a page using :::include.
tags:
  - authoring
  - remote
---

## Content includes

The `:::include` block inlines content from a local file or remote URL
directly into the page at render time. The included content is processed
through the full pipeline and baked into the cached page.

### Syntax

    ::: include
    path/to/file.md
    :::

    ::: include ttl=300
    https://example.com/remote-content.md
    :::

The optional `ttl=N` modifier sets the parent page cache TTL in seconds
if no `ttl:` is set in the page front matter. Useful for pages that include
frequently updated remote content.

### Path resolution

- Starts with `/` - absolute from docroot
- Starts with `http://` or `https://` - remote URL fetch
- Otherwise - relative to the current `.md` file directory

### Content handling by file type

`.md` files
: Front matter stripped, body rendered as Markdown inline. The included
  file's `title` and `layout` front matter are ignored - only the body
  is used.

Code files (`.sh`, `.pl`, `.py`, `.yml`, `.json`, `.css` etc.)
: Wrapped in a fenced code block with the appropriate language identifier.

`.html` files
: Inserted bare - assumed to be a valid HTML fragment.

Unknown extensions
: Wrapped in `<pre>` with HTML entities escaped.

### Examples

Include a local Markdown partial:

    ::: include
    partials/shared-note.md
    :::

Include a remote file, refresh every 5 minutes:

    ::: include ttl=300
    https://raw.githubusercontent.com/owner/repo/main/CHANGELOG.md
    :::

Include a code file (renders as a syntax-highlighted code block):

    ::: include
    /examples/config-sample.yml
    :::

### Error handling

If a local file is missing or a remote fetch fails, the block renders
as a silent span with class `include-error` and a `data-src` attribute
recording the failed source path. A warning is written to the error log.
Expose errors during development:

    .include-error::before {
      content: "include failed: " attr(data-src);
      color: red;
      display: block;
    }

### Notes

- Includes are single-pass only - `:::include` inside an included `.md`
  file is not processed. This prevents infinite loops.
- Remote includes are fetched at render time and baked into the cache.
  The page cache TTL controls how often remote content is refreshed.
- The `ttl=N` modifier only sets the TTL if no `ttl:` key is present in
  the page front matter. Front matter always takes priority.
- For frequently updated remote content, combine with `ttl:` in front
  matter or the `ttl=N` modifier.

### See also

- [Remote content](/docs/remote-content) - remote pages and JSON index pattern
- [Authoring guide](/docs/authoring) - full front matter reference
