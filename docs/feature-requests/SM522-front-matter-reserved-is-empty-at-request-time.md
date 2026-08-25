---
title: "SM522: FRONT_MATTER_RESERVED is empty at request time"
subtitle: "Under CGI and FastCGI the reserved-key list is never populated, so page front matter overrides values the engine reserves."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the processor structural review, PROVEN by probe tmp/proc-probe-reserved.t; class: security-integrity; recommended timing: BEFORE-BETA-PUBLISH. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. our %FRONT_MATTER_RESERVED at lazysite-processor.pl 5343 sits below the dispatch (1812-1834), so under a real CGI or FastCGI run it is empty when the request is served: the SM293 shape again, with our instead of my, which t/lint/39 excludes at line 107. Verified against the real processor as a subprocess: a page declaring auth: none and layout: default renders [% page_auth %] as none and [% page_layout %] as default; t/unit/processor/60 passes only because its subprocess page never sets layout. Reserved keys reach the stash as page_<key> (escaped, so no injection) and scan records carry auth, layout, register and search as custom keys. Fix: a _front_matter_reserved() sub, t/lint/39 widened to our, and a real assertion in test 60."
---

# The finding

`our %FRONT_MATTER_RESERVED = map {...}` at `lazysite-processor.pl 5343`
sits below the dispatch (`1812-1834`), so under a real CGI or FastCGI run
it is empty at request time. This is the SM293 shape again with `our` in
place of `my`, and t/lint/39 excludes `our` from its check (line 107).
Verified against the real processor as a subprocess: a page declaring
`auth: none` and `layout: default` renders `[% page_auth %]` as `none` and
`[% page_layout %]` as `default`. t/unit/processor/60 passes only because
its subprocess page never sets `layout:`. Reserved keys reach the stash as
`page_<key>` (escaped, so no injection) and scan records carry `auth`,
`layout`, `register` and `search` as custom keys; computed keys still win.

# Why it matters

Security-integrity: front matter overrides values the engine reserves for
itself, and a listing built from scan records can expose a gated page's
`auth` setting as if it were ordinary page data.

# The proving test

From the table row: `_front_matter_reserved()` sub; widen t/lint/39 to
`our`; real assertion in t/unit/processor/60 (`tmp/proc-probe-reserved.t`
is the model) – a subprocess page setting `layout:` and `auth:` renders
neither as `page_layout` nor `page_auth`.

# Fix shape

The shape lint/39 prescribes: replace the file-scoped hash with a
`_front_matter_reserved()` sub, widen t/lint/39 to catch `our` as well as
`my`, and give test 60 a page that sets a reserved key. The report asks
that this land as its own change, separate from the processor tidy
batches.
