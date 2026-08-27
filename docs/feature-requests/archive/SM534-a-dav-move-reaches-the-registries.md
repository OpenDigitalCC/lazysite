---
title: "SM534: a DAV move reaches the registries"
subtitle: "A WebDAV MOVE or COPY leaves the sitemap listing the old URL and missing the new one, where the manager's move clears the cache."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): do_copy_move calls the one helper _invalidate_registries_as (the require + local DOCROOT + eval pair do_put and do_delete typed twice, now typed once) after the alias reindex, so a MOVE or COPY over WebDAV clears the registry cache exactly as action_move / action_copy do. Proving test: two SM534 subtests in t/integration/74 - after a MOVE the cache is gone, the sitemap lists the new URL and no longer the old; after a COPY the cache is gone. The copy itself is NOT asserted listed: a copy is born with an owner-only ACL entry on both surfaces and the processor's _acl_governed hides any entry from the registries, so the manager's own copy is absent from the sitemap on the same fixture - a separate finding about what governed means, to file on its own. FOUND 2026-08-25 by the frontdoor structural review, PROVEN by probe tmp/fd-probe-move-registries.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. SM483 wired invalidate_registries into do_put (lazysite-dav.pl 554) and do_delete (651) only; do_copy_move at 741-899 has no call. After a MOVE of content/a.md to content/b.md the cache under lazysite/cache/registries/ survives and /sitemap.xml still lists /content/a and omits /content/b; after a COPY the copy is absent. The control, Files::action_move on the same fixture, clears the cache. Fix: the review's FD-5 wrapper called once after the commit in do_copy_move."
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
