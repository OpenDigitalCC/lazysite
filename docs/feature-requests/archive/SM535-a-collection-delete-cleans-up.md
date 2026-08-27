---
title: "SM535: a collection delete cleans up"
subtitle: "A WebDAV DELETE of a folder leaves the registries and the alias map pointing at pages that no longer exist - a 301 to a 404."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): do_delete lists the pages the entry covers BEFORE the removal - a .md path is its own list, a collection is walked through Aliases::md_rels (the walker reindex_move already used, now public) - and after the removal deindexes each page, drops its per-host render copies, and invalidates the registries whenever a page went. The brief store needed nothing: it mirrors the tree, so the directory key already took its entries with it. Proving test: NEW t/unit/dav/23-a-collection-delete-cleans-up.t - after the collection DELETE the alias lookup is undef, the registry cache is gone and the re-rendered sitemap no longer lists the page; the single-file DELETE stays as the control. Caveat carried from reindex_move: the walk is over the public spelling, so a gated COLLECTION (private store) is still not enumerated; a gated single page is. FOUND 2026-08-25 by the frontdoor structural review, PROVEN by probe tmp/fd-probe-delete-collection.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. do_delete keys its registry, alias and brief housekeeping on a path ending in .md (lazysite-dav.pl 647-655), which a directory never matches, while remove_tree removes every page under it. After DELETE of content/sec/ the sitemap still lists /content/sec/p and Aliases::lookup('/old-page') still answers /content/sec/p. The single-file DELETE control passes. The manager has no counterpart because it refuses a non-empty directory (Manager/Files.pm 780-793), so this is DAV-only. Fix: enumerate the .md files under the directory before remove_tree, deindex each, drop each brief entry, and invalidate the registries whenever anything was removed."
---

# The finding

`do_delete` keys registry, alias and brief housekeeping on `$a{rel}
=~ /\.md\z/` (`lazysite-dav.pl 647-655`), which a directory never
matches, while `remove_tree` removes every page under it. After
DELETE of `content/sec/` the sitemap still lists `/content/sec/p` and
`Aliases::lookup('/old-page')` still answers `/content/sec/p` - a 301 to a
404. The single-file DELETE control passes. The manager has no counterpart
(it refuses a non-empty directory, `Manager/Files.pm 780-793`), so this
is DAV-only.

# Why it matters

Correctness: the alias map and the registries are promises about what the
site serves. After a collection delete they promise pages that are gone,
and a visitor following an old link is redirected to a 404.

# The proving test

NEW `t/unit/dav/23-a-collection-delete-cleans-up.t`, one assertion:
the alias lookup is undef after the DELETE.

# Fix shape

Enumerate the `.md` files under the directory before `remove_tree` (the
shape of `Aliases::_md_rels`), deindex each and drop each brief entry,
and invalidate the registries whenever anything was removed.
