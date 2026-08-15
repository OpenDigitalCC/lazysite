---
title: "SM318 - one navigation implementation, reachable per domain from both surfaces"
subtitle: "MCP could not address a domain, and had its own implementation missing the cache invalidation that makes a nav change visible at all"
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10. lib/Lazysite/Manager/Nav.pm holds the implementation, MOVED verbatim rather than rewritten; both surfaces import it; read_nav and set_nav take `host` with the wording activate_layout already set for the identical ambiguity. The REPORTED defect was the missing host. Reading it found MCP had its own implementation lacking the SM168 cache invalidation, so an MCP nav edit returned ok:1 and the site served the old menu - worse than the reported defect, and unnoticed because the file really had been written. VERIFIED by t/unit/mcp/20, shown to fail before the extraction."
---

# What was found

`nav-read` and `nav-save` take a `host` on the control API. `read_nav` and
`set_nav` refused one, so an MCP-only account holding `manage_nav` could not
manage navigation for any domain except the primary - on an instance whose
headline feature is many first-class domains (SM151).

The refusal itself was correct: `set_nav` declares `additionalProperties: false`
and SM278 is right that an unknown argument should be refused rather than
ignored. What was wrong is that `host` was unknown.

Reading it found more than the report could see from outside:

```datatable
columns: | control API | MCP (before)
widths: 5.4cm | 4.4cm | X
bold: 1
tone: medium
---
per-domain `nav_file` | yes, via `host` | hard-coded `lazysite/nav.conf`
reports `inherited` | yes | no
content history (SM085) | explicit commit | via the generic file save
cache invalidation (SM168) | yes, with a count | **none**
---
```

The last row is worse than the reported defect. The nav is baked into every
page's rendered HTML, so a nav change is invisible on the live site until each
page re-renders; SM168 taught the control API to bust the cache and report how
many pages it refreshed, precisely so the caller could tell PUBLISHED from merely
saved. An MCP nav edit did none of that.

# Why extraction rather than a parameter

Two implementations of one operation drift, and the drift is **silent by
construction** because each surface is individually consistent. SM301 established
the answer when the gap ran the other way: one implementation serves both
channels, so they cannot answer differently.

# Related

SM301 (the same gap reversed), SM288, SM239 and SM289 (surface parity), SM151
(multi-domain, which is what makes this reachable), SM278 (the refusal that was
correct), SM268 (the docroot-relative path the reader must keep returning).
