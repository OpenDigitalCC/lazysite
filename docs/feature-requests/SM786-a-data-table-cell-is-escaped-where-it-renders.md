---
id: SM786
title: "SM786: a data-table cell is escaped where it renders"
subtitle: "Security review, 0.13.8, VERIFIED AND REPRODUCED HERE: db-bound table values reach the page stash raw, the page-render Template engines set no AUTO_FILTER, and the shipped examples teach the loop without a filter - so whoever can write a row controls markup, and therefore script, on every page that displays that table. Front-matter scalars in the same stash ARE escaped, which is what makes this an asymmetry rather than a policy."
brand: plain
standard-margins: true
status: candidate
---

# The finding, and what was verified

Filed by the security review as High. Every load-bearing claim was checked
against the source here before accepting it, and the injection was reproduced
independently rather than taken from the brief:

- **No `AUTO_FILTER` anywhere.** A grep across `lazysite-processor.pl` and
  `lib/Lazysite/` finds none, so `[% p.name %]` emits the cell verbatim.
- **`resolve_db` stashes raw.** `$vars{$key} = $v;` (~5222) takes the row
  hashes from `Lazysite::Data::Tables` as they are.
- **Front-matter and the auth context in the SAME stash are escaped**, through
  `_esc_html` (~6571), with a comment explaining why. So the engine already
  holds the rule; the db path is outside it.
- **CSP does not cover the gap on a default site.** `_csp_mode` returns
  `report-only` when unset (`SecurityHeaders.pm:101`), and report-only logs
  without blocking.
- **The shipped example teaches the unfiltered form**:
  `starter/docs/data-tables.md:110` is
  `[% FOREACH p IN products %]<li>[% p.name %] - [% p.price %]</li>[% END %]`.

Reproduced in `tmp/xss-repro.pl` against the engine's own Template
construction, in both contexts that matter:

    <li data-note=""><script>alert(3)</script>"><script>alert(1)</script></li>

element text AND an attribute breakout, from one row. The same row through
`| html` comes out `&lt;script&gt;...`, so the escape exists and is simply not
applied.

# Why this is worth a release

The row writer is not always the operator. A public form populating a table, an
imported CSV, a custom data app and a connector answer (a remote HTTP response)
all reach the same sink, and the first and last of those are reachable by
someone who has no account. The victim is every visitor to the page, and on a
gated page it is an authenticated session.

# What is asked, and the one decision behind it

Escape at the sink, so a page author cannot forget - either `AUTO_FILTER =>
'html'` on the page-render engines, or `_esc_html` in `resolve_db` as
front-matter already is. `_esc_html` escapes the apostrophe as well as
`< > & "`, so one default covers element text and either quoting style.

**The decision is what happens to a column that legitimately holds authored
HTML.** A safe default needs an explicit opt-out (`| raw`, or a marked-safe
convention) or it breaks intentional rich content on sites that have it today.
That is a rendering-behaviour change for every site, which is why this is filed
as a candidate for the release manager rather than built: the fix is small, the
blast radius is not.

With the sink settled, three things follow: update
`starter/docs/data-tables.md` and the other examples so the taught pattern is
the safe one, a `t/` case that puts `<script>` in a cell and asserts the render
is escaped, and the connector answer treated as untrusted wherever else it
surfaces.

# Provenance

`inbox/2026-09-08-db-table-cells-render-unescaped-stored-xss.md` and the
connector face of it in
`inbox/2026-09-08-connector-answer-and-table-render-xss.md`. Accepted after
independent verification.
