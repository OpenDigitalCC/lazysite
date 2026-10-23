---
title: Filtered scan
subtitle: Filter scan: results by field value to build sub-indexes and custom pages.
tags:
  - authoring
  - template
---

## Filtered scan

The `filter=FIELD:VALUE` modifier on `scan:` patterns filters results
before they are returned as a TT variable. Multiple filters are ANDed.

### Syntax

    pages: scan:/path/*.md filter=FIELD:VALUE

### Operators

Equality (scalar fields):

    pages: scan:/blog/*.md filter=date:2026-03-20

Array contains (for tags):

    pages: scan:/blog/*.md filter=tags:tutorial

Greater than (string comparison, works for ISO dates):

    pages: scan:/blog/*.md filter=date:>2026-01-01

Less than:

    pages: scan:/blog/*.md filter=date:<2026-06-01

Boolean:

    pages: scan:/*.md filter=searchable:true

### Multiple filters

Multiple `filter=` modifiers are ANDed together:

    pages: scan:/blog/*.md filter=tags:tutorial filter=date:>2026-01-01

### Examples

Tag-based sub-index:

    api_docs: scan:/docs/*.md filter=tags:api sort=title asc

Searchable pages only:

    search_index: scan:/*.md filter=searchable:true sort=date desc

Recent posts in a specific category:

    recent_tutorials: scan:/blog/*.md filter=tags:tutorial filter=date:>2026-01-01 sort=date desc

### In page content

    ---
    title: API Documentation
    tt_page_var:
      api_pages: scan:/docs/*.md filter=tags:api sort=title asc
    ---

    [% FOREACH page IN api_pages %]
    - [[% page.title %]]([% page.url %]) - [% page.subtitle %]
    [% END %]

### Recursive scanning

Use `**` to scan all subdirectories:

    all_docs: scan:/**/*.md filter=searchable:true sort=date desc

### Notes

- Filters apply after scanning but before sorting - sort order is
  preserved
- Unknown field names return empty results rather than erroring
- Tag filtering matches case-insensitively
- Date comparison is string-based - use ISO format (YYYY-MM-DD)
- See [Page scan](/docs/features/authoring/page-scan) for the base
  scan: feature
