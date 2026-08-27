---
title: "SM536: a nav write reaches every cached page"
subtitle: "nav.conf written over WebDAV leaves every cached page on the old navigation, and a per-domain nav file misses on the manager side too."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): the processor-side fix the filing prefers. The nav file a request renders with (the alias host's nav_file, the site's, or lazysite/nav.conf) is one definition, _nav_file_for, used by resolve_site_vars and now by try_serve_cache, which treats a cached render as stale when that file is newer - on the mtime and the TTL branches alike, the way lazysite.conf already was. That covers every writer at once and the per-domain file with the shared one. The manager's sweep is unchanged: its file-save cannot reach a nav-<site>.conf (Common::LAZYSITE_OPEN_EXACT admits nav.conf alone) and the per-domain nav-save already invalidates through action_cache_invalidate, so the second gap the review named is closed by the processor check rather than by widening a regex that nothing could trip. Proving test: NEW t/integration/75-a-nav-write-reaches-every-cached-page.t - one assertion per surface on the RENDERED nav: a DAV PUT of nav.conf, a DAV PUT of a per-domain nav-xisl.conf (the primary's render untouched), and the manager's action_save as the control. FOUND 2026-08-25 by the frontdoor structural review, PROVEN by probe tmp/fd-probe-nav-cache.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. action_save answers a nav.conf write with _invalidate_all_html (Manager/Files.pm 567-569, SM087); do_put answers with invalidate_cache($abs) (lazysite-dav.pl 537), a no-op for a non-.md path, and the processor's try_serve_cache keys freshness on the .md and lazysite.conf mtimes only (lazysite-processor.pl 1980-2012), never on the nav file. After a DAV PUT of lazysite/nav.conf, index.html survives and the next render still carries the old entry; the control through action_save renders the new one. A second gap: the manager's trigger regex matches nav.conf only, so a per-domain lazysite/nav-<site>.conf (SM443) misses on the manager side too. Prefer the processor-side fix: the resolved nav file's mtime in the cache key covers every writer at once."
---

# The finding

`action_save` answers a nav.conf write with `_invalidate_all_html`
(`Manager/Files.pm 567-569`, SM087); `do_put` answers with
`invalidate_cache($abs)` (`lazysite-dav.pl 537`), a no-op for a non-`.md`
path, and the processor's `try_serve_cache` keys freshness on the `.md` and
`lazysite.conf` mtimes only (`lazysite-processor.pl 1980-2012`) - never on
the nav file. After a DAV PUT of `lazysite/nav.conf` (204), `index.html`
survives and the next render still carries the old entry; the control
through `action_save` renders the new one. A second gap sits inside the
first: the manager's trigger is `m{(?:^|/)nav\.conf$}`, so a per-domain
`lazysite/nav-<site>.conf` (SM443) misses it on the manager side too.

# Why it matters

Correctness: navigation is the one element on every page, and a stale
copy of it on every cached page means the whole site advertises the old
structure until each page is next edited. Both write surfaces need the
same answer, and the per-domain nav file today gets it from neither.

# The proving test

NEW `t/integration/75-a-nav-write-reaches-every-cached-page.t`, one
assertion per surface on the rendered nav.

# Fix shape

The durable fix is in the processor: compare the resolved nav file's
mtime in `try_serve_cache`, which covers every writer at once. The
surface-local alternative is `do_put` calling `_invalidate_all_html`
when `$a{conf}{nav_files}{$a{rel}}`; the processor-side fix is the one
to prefer.
