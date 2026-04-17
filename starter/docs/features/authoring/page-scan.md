---
title: Page scan
subtitle: Scan a directory and return page metadata as a TT array variable.
tags:
  - authoring
  - template
---

## Page scan

The `scan:` prefix in `tt_page_var` scans a directory for `.md` files
and returns an array of page objects. Use it to build indexes, listings,
and navigation from page metadata.

### Syntax

    ---
    tt_page_var:
      pages: scan:/blog/*.md sort=date desc
    ---

### Pattern rules

- Must start with `/` (docroot-relative)
- Must end with `.md`
- Uses Perl's `glob()` - standard shell glob patterns work
- Maximum 200 files returned per scan
- Files outside the docroot are excluded (realpath check)

### Page object fields

Each scanned page returns these fields:

- `url` - docroot-relative URL (`.md` stripped, `/index` normalised to `/`)
- `title` - from front matter `title:` or empty string
- `subtitle` - from front matter `subtitle:` or empty string
- `date` - from front matter `date:` or file mtime (YYYY-MM-DD format)
- `tags` - array of tags from front matter (YAML list, comma-separated,
  or single value)
- `path` - full filesystem path to the `.md` file

### Sort modifier

Append `sort=FIELD DIRECTION` to the pattern:

    scan:/blog/*.md sort=date desc
    scan:/docs/*.md sort=title asc
    scan:/pages/*.md sort=filename asc

Supported fields: `date`, `title`, `filename`. Default: `filename asc`.
Direction is optional and defaults to `asc`.

### Example

    ---
    title: Blog
    tt_page_var:
      posts: scan:/blog/*.md sort=date desc
    ---
    [% FOREACH post IN posts %]
    ### [% post.title %]

    *[% post.date %]* - [% post.subtitle %]

    [Read more]([% post.url %])
    [% END %]

### Notes

- Scans can also be defined in `lazysite.conf` for site-wide variables
- Tags are parsed from YAML list format, comma-separated strings, or
  single values into an array: `[% page.tags.join(', ') %]`
- The scan is performed at render time - results reflect the current
  state of the filesystem
- [TT variables](/docs/features/authoring/tt-variables) - all variable
  sources and types
