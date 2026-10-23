---
id: SM1258
title: "SM1258: a WebDAV delete takes a page's stem rule with it"
subtitle: "WebDAV DELETE dropped the page's own rule only, so a rule keyed by the page's stem waited for the next page written there. It now drops it under the same rule as the manager's delete, through one shared function."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "found while measuring SM1242; fix asked by the release manager's coordinator, 2026-10-22"
area: dav
status-note: "SHIPPED (0.16.1) on n725: WebDAV DELETE (and the housekeeping of a partial collection delete) call Acl::fold_page_stem before forget_path, as action_delete now does; SM1242's private helper in Files.pm is gone. t/unit/dav/34."
---

# What happened

[[SM1242]] made the manager's delete (`action_delete`, used by MCP `delete_page`, the
control API and the manager) drop a rule keyed by the page's stem. WebDAV's DELETE
dropped the page's own key only (SM212, CF-2). A page drafted through `/content/about`
and deleted over WebDAV left `content/about` in the store. The next page written there
was born a draft nobody set.

# What shipped

- **One function for every surface.** `Lazysite::Auth::Acl::fold_page_stem`
  ([[SM1257]]) folds a page's stem rule into its own key. It does this only while no
  folder of that name exists in the docroot or the private store; rules beneath the stem
  are never touched. `forget_path` then removes it with the page.
- WebDAV DELETE calls it, and so does the housekeeping of a collection delete that
  stopped partway (`_partial_delete_answer`), for each page that is gone.
- `action_delete` now calls the same function. SM1242's private helper in Files.pm is
  removed, so the two surfaces cannot drift apart again.

# Tests

t/unit/dav/34 has two new subtests:

- a stem-drafted page deleted over WebDAV takes `content/about` with it;
- deleting a folder's landing page over WebDAV leaves the folder's rule.

With `lazysite-dav.pl` reverted, the first fails. t/unit/manager/160's SM1242 subtest
still passes through the shared function.
