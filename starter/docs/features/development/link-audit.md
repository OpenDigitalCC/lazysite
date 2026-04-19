---
title: Link audit
subtitle: Find orphaned pages and broken internal links.
tags:
  - development
---

## Link audit

The `lazysite-audit.pl` script scans the docroot for orphaned pages
(pages that exist but are not linked from anywhere) and broken internal
links (links pointing to pages that do not exist).

### Invocation

    perl tools/lazysite-audit.pl [options] [docroot]

The docroot defaults to the current directory.

### Options

- `--exclude path,path,...` - comma-separated canonical paths to
  exclude from the orphan report (e.g., `--exclude index,404`)
- `--exclude-file FILE` - file containing one exclusion per line

### What it scans

- All `.md` files for Markdown link syntax and HTML
  `href`/`src` attributes
- Cached `.html` files for `.url` pages (since remote content is
  not re-fetched)
- All `.tt` files under `lazysite/templates/` for template links

### What it skips

- External links (`http://`, `https://`)
- Mailto links, fragment-only links (`#`), data URIs
- Asset file extensions (images, fonts, CSS, JS, PDFs, archives,
  media)
- Paths starting with `assets/`
- Links containing TT variables (`[%`)
- Files in the `lazysite/` directory (system files)

### Report format

    ORPHANED PAGES (N)
      /path          source-file.md

    BROKEN LINKS (N)
      source-file.md  -> /target

    SUMMARY
      Source pages:    N
      Orphaned:        N
      Broken links:    N

### Default exclusions

`404` and `index` (root page) are always excluded from the orphan
report.

### Notes

- Canonical paths strip the file extension and normalise `/index`
  to the parent path
- The audit is read-only - it does not modify any files
- Run after adding new pages to find unlinked content
