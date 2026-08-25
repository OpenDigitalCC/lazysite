---
title: "SM534: a DAV move reaches the registries"
subtitle: "A WebDAV MOVE or COPY leaves the sitemap listing the old URL and missing the new one, where the manager's move clears the cache."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the frontdoor structural review, PROVEN by probe tmp/fd-probe-move-registries.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. SM483 wired invalidate_registries into do_put (lazysite-dav.pl 554) and do_delete (651) only; do_copy_move at 741-899 has no call. After a MOVE of content/a.md to content/b.md the cache under lazysite/cache/registries/ survives and /sitemap.xml still lists /content/a and omits /content/b; after a COPY the copy is absent. The control, Files::action_move on the same fixture, clears the cache. Fix: the review's FD-5 wrapper called once after the commit in do_copy_move."
---

# The finding

SM483 wired `invalidate_registries` into `do_put` (`lazysite-dav.pl
554`) and `do_delete` (`lazysite-dav.pl 651`) only; `do_copy_move`
(`lazysite-dav.pl 741-899`) has no call. After a MOVE of `content/a.md` to
`content/b.md` the cache under `lazysite/cache/registries/` survives and
`/sitemap.xml` still lists `/content/a` and omits `/content/b`; after a
COPY the copy is absent. The control (`Files::action_move` on the same
fixture) clears the cache.

# Why it matters

Correctness: one operation, two implementations, two answers. A page
renamed over WebDAV is invisible to search engines at its new URL and
advertised at a URL that now 404s, until something unrelated regenerates
the registries.

# The proving test

Two subtests in `t/integration/74` asserting the cache is gone and the
new URL listed.

# Fix shape

Extract the require + local DOCROOT + eval pair that
`do_put` and `do_delete` already write (the review's FD-5
`_invalidate_registries_as($user)`) and call it once after the commit in
`do_copy_move`.
