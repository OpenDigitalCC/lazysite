---
title: Registries
subtitle: Generate sitemap.xml, llms.txt, and other files from page metadata.
tags:
  - authoring
  - configuration
---

## Registries

Registries are auto-generated files (sitemap, feeds, indexes) built
from page metadata. Pages opt in by listing registry names in their
`register:` front matter. Registry templates in
`lazysite/templates/registries/` define the output format.

### Syntax

In page front matter:

    ---
    title: My Page
    register:
      - sitemap.xml
      - llms.txt
    ---

### How it works

When any page is rendered, lazysite checks if any registry output file
is missing or older than the registry TTL (14400 seconds / 4 hours by
default). If so, it scans all `.md` files under the docroot, collects
pages with `register:` front matter, and renders each registry template
with the matching pages.

### Registry templates

Templates are TT files in `lazysite/templates/registries/`. The
template filename (minus `.tt`) becomes the output filename in the
docroot. For example, `sitemap.xml.tt` generates `sitemap.xml`.

Available variables in registry templates:

- `pages` - array of registered pages, each with:
  `url`, `title`, `subtitle`, `date`, `register`
- All site variables from `lazysite.conf`

### Adding a new registry

Create a `.tt` file in `lazysite/templates/registries/`:

    [% FOREACH page IN pages %]
    [% page.url %] - [% page.title %]
    [% END %]

Then add the registry name (filename without `.tt`) to pages that
should be included.

### Example

    ---
    title: About Us
    register:
      - sitemap.xml
      - llms.txt
      - feed.rss
    ---

### Notes

- Only `.md` files are scanned for registration - `.url` files are
  skipped (reading remote content for registration is too expensive)
- Registries regenerate when any page is rendered and the output file
  is older than the TTL
- Delete the output file to force immediate regeneration on next
  page request
- The `register:` value names are matched against the template filename
  minus the `.tt` extension
- [RSS and Atom feeds](/docs/features/authoring/feeds) - feed-specific
  registry templates
