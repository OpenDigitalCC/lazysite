---
title: "SM481: the engine knew why the page was empty, and told nobody who could read it"
subtitle: "A `db:` binding that renders nothing logs its reason to the web server's error log, which the agent who wrote the page cannot reach. It now answers in validate_page, where they are already looking"
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND IN A FIELD REPORT'S ASIDE, not in its headline. The site agent spent an afternoon on a page rendering zero rows while the API returned three from the same table at the same moment, and wrote afterwards: 'nothing in the empty result said this table is not published. Even a render-log line would have turned an afternoon into a minute.' I checked, because SM476 DID add exactly that line - and it fires, to STDERR, which on a real install is the web server's error log. An agent working over MCP cannot read it. The message existed and was unreachable by the only person who needed it. ANSWERED STATICALLY IN validate_page instead: the descriptor already knows whether a visitor would see anything, without rendering. Three kinds, because the remedies differ - db-table-not-published (add public: true), db-table-missing (the table is not declared), db-binding-unchecked (the data modules are not loadable here). The published case is deliberately SILENT: a check that fires on correct pages is one an author learns to skim, and this one has to be read the day it matters. THE MESSAGE NAMES WHY THE TWO READINGS DISAGREE - 'the API and the manager still read it, so the page looks broken and the data looks fine' - because that contradiction is what cost the afternoon, and it is the same pair of symptoms a permissions fault and a WAL/writability fault produce. Read from the front-matter TEXT rather than the parsed hash: tt_page_var is nested, _parse_fm is flat, and a checker that silently saw no bindings would be a check that always passes. Six sabotages, all confirmed to fail t/unit/mcp/10 - including one that recognised only a bare `db:name` and fell silent on every binding carrying DP-2 modifiers or a scalar."
---

# What happened

```datatable
columns: What the agent saw | What it meant
widths: 6.6cm | X
bold: 1
tone: medium
---
The page rendered 0 rows | the table was not published
The API returned 3 rows from that table, at the same moment | the API is operator-gated and bypasses the visitor rule
Nothing anywhere said which | the reason went to a log they cannot read
```

That pair of symptoms -- **the API can see it and the page cannot** -- is also
what a permissions fault looks like, and what the WAL/writability fault I
wrongly suggested in SM473 looks like. There was no way to tell them apart from
outside, so the afternoon went on ruling things out.

# The message existed

SM476 added it:

> `db: page variable read nothing - if the table exists, it may not be
> published (set public: true) or this visitor may not be allowed to read it`

It fires. It goes to STDERR, which under a web server is the error log, which
an agent holding an MCP grant has no route to. **A diagnostic the person who
needs it cannot reach is not a diagnostic** -- it is a note to whoever has
shell access, about a problem they are not having.

# Where it goes instead

`validate_page`, which is the tool an author already runs against a page they
are unsure of, and which needs no render to answer: the descriptor knows.

The published case says nothing at all. A check that fires on correct pages is
one an author learns to skim past, and this one has to be read on the day it
matters.
