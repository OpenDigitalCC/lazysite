---
title: RSS and Atom feeds
subtitle: Publish syndication feeds from pages with register: feed.rss or feed.atom.
tags:
  - authoring
  - configuration
---

## RSS and Atom feeds

lazysite includes starter registry templates for RSS and Atom feeds.
Pages opt in to feeds by listing `feed.rss` or `feed.atom` in their
`register:` front matter.

### Syntax

    ---
    title: Blog Post Title
    subtitle: A brief description of the post.
    date: 2024-06-15
    register:
      - feed.rss
      - feed.atom
    ---

### Feed templates

The starter includes two feed templates in `registries/`:

- `feed.rss.tt` - generates `feed.rss` (RSS 2.0)
- `feed.atom.tt` - generates `feed.atom` (Atom 1.0)

Both templates use these page fields:

- `page.title` - entry title
- `page.url` - entry link (combined with `site_url`)
- `page.subtitle` - entry description/summary (optional)
- `page.date` - publication date

And these site variables from `lazysite.conf`:

- `site_name` - feed title
- `site_url` - base URL for absolute links

### Example

Add `date:` to front matter for meaningful feed ordering:

    ---
    title: Version 2.0 Released
    subtitle: Major update with new features.
    date: 2024-06-15
    register:
      - feed.rss
      - feed.atom
      - sitemap.xml
    ---

### Notes

- The `date:` front matter field is important for feeds - without it,
  the file mtime is used, which may not reflect the publication date
- Feed templates must be copied to `lazysite/templates/registries/`
  during installation - they are not included automatically
- Feeds regenerate on the registry TTL schedule (4 hours by default)
- Delete `feed.rss` or `feed.atom` from the docroot to force
  regeneration on next page request
- [Registries](/docs/features/authoring/registries) - how the registry
  system works
