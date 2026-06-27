---
title: "SM111 - file manager: sortable columns + pagination"
subtitle: "Sort by name/modified/type, and page beyond 50 files"
brand: plain
---

## What

Two file-manager ergonomics:

- **Sortable columns** - click a column header (Name, Modified, Access, Type) to sort
  ascending/descending; an indicator shows the active sort. Default name-ascending,
  directories first.
- **Pagination** - when a directory holds more than ~50 entries, paginate (or
  virtualise) rather than rendering them all; show a page control and a total count.
  The existing type/name filter should compose with sorting and paging.

## Why

Raised 2026-06-27 with the manager UI feedback. Large content trees are unwieldy in a
flat unsorted list.

## Shape

- Client-side for v1: the file list is already fetched per directory; sort + page in
  JS in `files.md`. Keep directories grouped above files when sorting by name/type.
- Page size ~50, configurable; remember the last sort in the session.
- If a directory is very large, consider a server-side paged listing later, but v1 can
  sort/page the already-returned list.

## Status

**SHIPPED in v0.4.34.** (see CHANGELOG)


Queued. Bounded, client-side in `files.md` (sort comparator + a slice + page control;
header click handlers and a sort indicator).
