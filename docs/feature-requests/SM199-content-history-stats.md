---
title: "SM199 - Content history: file list and revision statistics"
subtitle: "A table-of-contents view over the history, with per-file revision counts and dates"
brand: plain
status: candidate
status-note: "Implemented on branch claude/edge-sm199 (2026-07-24), pending review + integration. Engine: Lazysite::Git::files_summary. Read surface: control-API action git-history-summary + MCP tool list_content_history, both gated on manage_content exactly like git-history / list_versions. Manager: the Files page gained a 'History overview' button opening a sortable all-files table (path, revisions, first, latest, last author). Move to shipped on release."
---

::: widebox
The Content history panel currently answers "what happened to this file".
This adds the complementary view: "what does the history cover" - a file
list / table of contents, with basic statistics per file (revision count,
first and last revision dates, last author), so an operator can see at a
glance which content is churning, which is stable, and which has history
at all.
:::

# SM199 - Content history file list and statistics

## What is asked

- A file-list view: every path the content history covers, as a table of
  contents.
- Per file, basic statistics: number of revisions, date of first revision,
  date of most recent revision, and the last author.
- A site-level summary (total files under history, total revisions).

## Why

- With AI agents editing sites over MCP, the history is the operator's
  audit surface; a per-file statistics view turns it from a per-file
  drill-down into an overview of where change is happening.
- Churn is a signal: a page with many recent revisions is where attention
  (or a problem) is; a page untouched since import may need review.
- The rename-following history (SM175) already computes lineage; counts
  and dates are a cheap aggregation over data the plugin already holds.

## Shape (as implemented)

- Engine: `Lazysite::Git::files_summary($docroot)` enumerates the tracked
  content set at HEAD (`git ls-tree -r HEAD`, which info/exclude already
  keeps clean of secrets, caches and generated `*.html`) and aggregates each
  path's lineage-aware `file_log` (SM175 semantics) into
  `{ path, revisions, first, latest, last_author }`, plus a site-level
  `{ files, revisions }`. Counts follow renames and never leak across a
  delete/recreate boundary. Dates are commit epochs; bounded by the existing
  200-revision `file_log` cap per path.
- Control API / MCP: a read-only `git-history-summary` action and a
  `list_content_history` MCP tool, both gated on `manage_content` (exactly
  like `git-history` / `list_versions`), returning the rows + summary.
- Manager: the Files page History affordance gained an "All files" overview -
  a "History overview" toolbar button (shown only when the feature is
  enabled) opening a table sortable by path, revisions, first, latest and
  last author, with the site summary as a header line.
