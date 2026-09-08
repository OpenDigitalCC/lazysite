---
id: SM786
title: "SM786: a data-table cell is escaped where it renders"
subtitle: "Security review, 0.13.8, VERIFIED AND REPRODUCED HERE: db-bound table values reach the page stash raw, the page-render Template engines set no AUTO_FILTER, and the shipped examples teach the loop without a filter - so whoever can write a row controls markup, and therefore script, on every page that displays that table. Front-matter scalars in the same stash ARE escaped, which is what makes this an asymmetry rather than a policy."
brand: plain
standard-margins: true
status: candidate
status-note: "RULED 2026-09-08 by the release manager: escape by default, with a manager.conf override that is DEPRECATED THE DAY IT SHIPS. The override is set for the three sites that render db fields today, so nothing breaks; the sites agent then fixes those templates through routine updates; the override is removed once they are done. Design of record below - not yet built, and the release it rides is a separate decision."
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

# The ruling: escape by default, behind an override that is born deprecated

The release manager's decision, 2026-09-08. It answers the one question the
finding could not answer for itself - what happens to a site that renders
authored HTML out of a table today - and it answers it with a **migration**
rather than a permanent opt-out.

**Escape at the sink**, so a page author cannot forget: either `AUTO_FILTER =>
'html'` on the page-render engines, or `_esc_html` in `resolve_db` as
front-matter already is. `_esc_html` escapes the apostrophe as well as
`< > & "`, so one default covers element text and either quoting style.

**An override in `manager.conf`** turns the escaping off for a site that needs
the old behaviour while its templates are corrected. It is set for the three
sites that render db fields today, so nothing breaks on the day this ships, and
for nothing else.

**The override is deprecated the day it ships.** Not "deprecated when we get
round to it" - it is announced as deprecated in the same release that
introduces it, because its only purpose is to hold the door for three known
sites while they are fixed. That ordering matters: a compatibility flag with no
stated end becomes the configuration everyone copies.

**The sites agent corrects those templates through routine updates** - a
`| html` on each cell, or whatever the marked-safe convention turns out to be -
and reports when a site no longer needs the flag.

**The override is removed** once the three are done. Removing it is a release
of its own, and until then the flag's presence on a site is a to-do list with a
name.

Why this shape rather than a permanent `| raw`: an escape you can opt out of
per column is a feature, and features get used. A flag that exists to be
deleted, set on a known and shrinking list, cannot quietly become the way sites
are built.

# What follows once the sink is settled

- Update `starter/docs/data-tables.md` and the other examples so the taught
  pattern is the safe one. This is the half that stops the defect coming back:
  the current example is where a page author learns the unsafe form.
- A `t/` case that puts `<script>` in a cell, renders, and asserts the output
  is escaped - and a second that asserts the override still renders raw, so the
  flag's behaviour is pinned for as long as it exists.
- The three sites named in the override are the migration list; the flag is
  gone when it is empty.
- A connector answer treated as untrusted wherever else it surfaces (SM790's
  render half).

**Not built.** The design is settled; which release carries it is a separate
decision, and the escaping change should not be dropped into a release that is
already carrying four items without the release manager saying so.

# Provenance

`inbox/2026-09-08-db-table-cells-render-unescaped-stored-xss.md` and the
connector face of it in
`inbox/2026-09-08-connector-answer-and-table-render-xss.md`. Accepted after
independent verification.
