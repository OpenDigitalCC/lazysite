---
id: SM990
title: "SM990: a page the scan could not open failed every page that scanned it"
subtitle: "SM976 Q15h/Q15i guarded the parse of a page's front matter and body; the open, outside the guard, still died on a page the server's user may not read."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: WORK-PLAN-0153 follow-up, listed as WORK-PLAN-0154 P25
area: rendering
status-note: "SHIPPED (PENDING): resolve_scan and scan_pages leave out a page they cannot open and log it at WARN by its docroot-relative path with the reason, as Q15h does for encoding (t/unit/processor/98)."
---

# What was wrong

Both walks over page front matter - `resolve_scan` (a `scan:` source) and
`scan_pages` (the registries), lazysite-processor/registries.pm - called
`read_file` outside the guard SM976 Q15h put around the parse, and `read_file`
dies when `open` fails. One page the serving user may not read (a file copied
in by root with mode 0600) made every page whose scan reached it answer 500 -
the home page too when lazysite.conf names the scan - and the sitemap.
Reproduced with a mode-0 page.

# The fix

The read is inside the guard in both walks. The page is left out and logged
at WARN, "a page whose file cannot be opened is left out", with its
docroot-relative path and the reason; the server path in `read_file`'s
message is replaced by the relative one.

A scan's `_total` (SM988) still counts such a page: it matched, and was not
known to be unreadable until it was read.

# Tests

t/unit/processor/98 (skips as root, and where a mode-0 file opens): the home
page, a scan listing and the sitemap render; both walks return every readable
page, do not die, and log the page by its relative path with "Permission
denied" and no server path.
