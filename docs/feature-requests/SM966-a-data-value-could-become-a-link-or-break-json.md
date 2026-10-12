---
id: SM966
title: "SM966: A data value could become a link, or break an api page's JSON"
subtitle: "A query value or a db: row was HTML-escaped and nothing more - so Markdown link syntax in it became an anchor after the template pass, and a backslash or control character in it made an api page's response invalid JSON."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review, second pass (WORK-PLAN-0153 Q11b)
area: security
status-note: "SHIPPED (0.15.3): one helper, _data_inert, encodes [ ] \\ and the C0 controls (NUL as U+FFFD) as character references in every value the author did not write - the query stash, db: rows, and through _tt_inert the form prefill and banner. t/unit/processor/90 and 91, t/unit/data/65 fail without it."
---

# What was wrong

A query value and a db: row value enter the template stash HTML-escaped. Two
more readers see the page after that.

convert_p_links turns `[text](url)` in the rendered text into an anchor - it
exists for an author's link whose URL holds a template variable. A value
spelling that syntax became a link: `?x=[m](javascript:void)` printed by
`[% query.x %]` rendered `<a href="javascript:void">m</a>`, and a visitor-written
row did the same on every page listing it.

An `api: true` page puts the value inside a JSON string. A trailing backslash,
a tab or any other control character reached it raw, and the response no longer
parsed.

A NUL in a value could also spell convert_p_links' own placeholder and pull a
protected tag - the layout's `<script>` element - into the text.

# The fix

`_data_inert`, applied after the HTML escape to every value the page's author
did not write: `[` and `]`, `\`, and the C0 controls become character
references (NUL becomes U+FFFD, which is what an HTML parser shows for it). A
browser displays them as typed; in JSON they are plain text. The query stash
(`_esc_query_value`), the db: rows (`_escape_db_rows`) and the pre-template sinks
(`_tt_inert`, which keeps `%` on top) all use it, so the three cannot drift.

A template that adds `| html` to such a value escapes it twice, as before
([[SM869]]); the extra characters are visible as entity text in that case.

# Evidence

t/unit/processor/90 (api JSON, NUL), t/unit/processor/91 (link syntax in a query
value) and t/unit/data/65 (a row as a link and in an api page) were committed
first with these marked TODO. With `_data_inert` made a no-op, they fail again.

# Related

[[SM869]], [[SM964]], [[SM965]], [[SM786]].
