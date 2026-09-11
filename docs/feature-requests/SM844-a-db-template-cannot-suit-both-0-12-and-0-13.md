---
title: "SM844: a template reading a data table cannot be written for both 0.12 and 0.13, and the upgrade breaks it silently"
subtitle: "Sites agent, 2026-09-11: 0.12 renders a stored value as live HTML and needs | html; 0.13 escapes at the sink and | html double-escapes. The data-tables page says nothing about either"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. Options 1 and 2 are built, and the two save shapes alongside. The data-tables page now says db: values are escaped for you from 0.13.0, that | html on top double-escapes, and what to do on 0.12; it also documents both data-row-save shapes. lazysite check lists every page whose front matter binds db: and whose text applies | html inside [% %], across the docroot and the private store, skipping the engine tree; a page with db: and no html, or html and no db:, is not listed. Option 3 (an idempotent | html) is not taken: it needs a marker type on every escaped value, and the check names the files before anyone renders them."
---

# What was measured

One row holding `<b>bold</b> & amp`, bound with `db:`, rendered anonymously:

| Engine | Template | A visitor sees |
| --- | --- | --- |
| 0.12.1 | `[% r.label %]` | **bold** - a live `<b>` element |
| 0.13.12 | `[% r.label %]` | `<b>bold</b> & amp` - correct |
| 0.13.12 | `[% r.label \| html %]` | `&lt;b&gt;...` - **double-escaped** |

SM786's escape by default is built and works. The finding is the seam: neither
template is portable, and **the failure on upgrade is silent in both directions**
- a site that added `| html` because it was right on 0.12 starts showing
`&amp;lt;` the day it upgrades, and only for values containing `&`, `<`, `>` or
`"`, so it can sit unnoticed until someone adds "Smith & Jones".

Confirmed here: `starter/docs/data-tables.md` does not mention escaping at all.
SM786 changed how every db value renders and the page an author reads was not
told.

# What would close it, cheapest first

1. **The data-tables page says it**: values are escaped on output from 0.13.0,
   do not add `| html`, and on an earlier release either upgrade or keep markup
   out of tables a page renders.
2. **An upgrade check** that lists pages carrying a `db:` binding and `| html`
   inside `[% %]` - the files a 0.12 author made correctly and 0.13 breaks.
   SM786's log already names the table and column at render; this names the file
   before anyone renders it.
3. `| html` idempotent on a value the sink escaped - removes the choice, and
   needs a marker or wrapper type to know which values those are.

# Alongside, and cheap

The two `data-row-save` shapes are not documented: an insert carries the key
inside `row`; an update passes a top-level `key` and must not repeat it inside
`row` - doing so is refused as *"'slug' is the row's key and cannot be changed by
an update"*, which reads like a mistaken edit rather than the wrong call shape.

# Related

[[SM786]] (the escaping), [[SM842]] (why it matters more once forms can write
tables).
