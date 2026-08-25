---
title: "SM581: writing a nav-shaped file under a content root succeeds, rebuilds every page, and changes nothing"
subtitle: "A per-domain nav lives where the domain's nav_file says. A file created at <content-root>/lazysite/nav.conf is ordinary content: inert, unread, and reported as a success with a cache rebuild."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33: a write whose path ends `lazysite/nav.conf` and is not the resolved nav for any configured domain is REFUSED (kind `nav-not-here`), naming set_nav, its `host` argument and - via Domains::host_for_path - the domain whose content root the caller was writing into. Refusal rather than a warning because the legitimate set is enumerable: the new Nav::resolved_nav_files derives every path that IS a navigation from Domains::domains_list (so inheritance and alias.<host>.nav_file resolve exactly as _nav_conf_info resolves them), each of those is let through, and that includes a domain whose nav_file genuinely sits at that shape - no legitimate write reaches the refusal. THE CACHE CLAIM was the second half and is fixed with the same set: action_save keyed `cache_rebuilt: all-pages` on ANY path ending nav.conf, against the caller's raw string rather than the canonical rel, so an ordinary file with that name deleted every generated render on the instance and claimed a rebuild it had nothing to do with; it now invalidates and claims only for a resolved nav, and _invalidate_all_html returns the number of renders it dropped so the reply carries `cache_cleared: <n>` - the fact rather than the label. NOT COVERED, and the same shape: the WebDAV PUT path (lazysite-dav.pl) and Files' move/copy destinations reach the same wrong place without this guard. t/unit/manager/112 holds all four outcomes. ORIGINAL NOTE: FOUND BY THE SITE AGENT 2026-08-25 while working a client brief: it wrote /sites/xisl/lazysite/nav.conf, received created:1 and cache_rebuilt:all-pages, and the live nav did not change - it flagged the stray file itself rather than leaving it. VERIFIED FROM CODE: the processor resolves a site's nav as $DOCROOT/<nav_file> when the domain declares one, else $LAZYSITE_DIR/nav.conf; a path under a content root is neither, and since it does not begin with lazysite/ it is not blocklisted either, so it lands as ordinary content. THE CORRECT ROUTE EXISTS: Manager::Nav::action_nav_save takes a host and resolves per-domain nav_file including alias.<host>.nav_file, and SM318 unified MCP's set_nav onto it precisely because MCP used to hard-code lazysite/nav.conf - THE SAME DEFECT CLASS, one layer out: SM318 fixed the tool, and a raw file write reaches the same wrong place with no tool to correct it. PROPOSED: refuse (or loudly warn on) a write whose path ends lazysite/nav.conf but is not the resolved nav for any domain, naming set_nav and the host argument; and have the cache-rebuild claim reflect what was actually invalidated. PLANNED for 0.10.33."
---

# The trap

A file named `lazysite/nav.conf` under a content root looks exactly like
the real thing, is accepted as ordinary content, and reports the same
success - including a cache rebuild that rebuilds pages whose nav did
not change. Nothing in the reply distinguishes it from the write that
would have worked.

# Proving test

A write to `<content-root>/lazysite/nav.conf` on a domain whose
`nav_file` is elsewhere is refused (or warns naming `set_nav` and
`host`), and the live nav is unchanged either way; `set_nav` with the
host still succeeds and does change it.
