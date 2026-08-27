---
title: "SM537: twenty-two tools carry the default annotation"
subtitle: "Reads are advertised as open-world writes and destructive tools as safe, and clients drive per-call approval from these hints."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): all 22 tools now carry an explicit [readOnly, destructive, openWorld] entry in %ANNOTATE (reads read-only; drop/delete/rebuild/site_apply destructive); proving test in t/lint/85 (every table entry is annotated, no stale entries) plus t/unit/mcp/01 (delete_theme destructive). %READ, the audit-skip list, is deliberately left alone: it decides what reaches the audit trail, where a PII read is audited on purpose. FOUND 2026-08-25 by the mcp structural review, PROVEN by probe tmp/mcp-probe-anomalies.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. %ANNOTATE at lazysite-mcp.pl 3010 names 47 of 69 tools; the other 22 fall to the default [0,0,1], so describe_capabilities, list_domains, list_data_tables, describe_data_table, read_data_rows, read_form_submissions, analyse_visitors, preview_public_page and preview_domain advertise readOnlyHint:false and openWorldHint:true, while drop_data_table, delete_data_row and delete_theme advertise destructiveHint:false. The header comment says ChatGPT drives per-call approval from these hints. %READ at 3395 is a third list that disagrees with %ANNOTATE on five tools. Fix: an annotate key on each tool entry, %ANNOTATE removed, %READ derived from readOnly, and t/lint/23 asserting the key is present on every entry."
---

# The finding

`%ANNOTATE` (`lazysite-mcp.pl 3010`) names 47 tools; 22 fall to the
default `[0,0,1]`. As a result `describe_capabilities`, `list_domains`,
`list_data_tables`, `describe_data_table`, `read_data_rows`,
`read_form_submissions`, `analyse_visitors`, `preview_public_page` and
`preview_domain` advertise `readOnlyHint:false, openWorldHint:true`, while
`drop_data_table`, `delete_data_row` and `delete_theme` advertise
`destructiveHint:false`. A separate `%READ` map (3395) disagrees with
`%ANNOTATE` on five tools (`read_brief`, `list_briefs`,
`list_data_safety_exports`, `read_data_safety_export`,
`list_layout_catalogue`), which are read-only there but audited as writes.
The map sits 1,450 lines from the table it annotates.

# Why it matters

Correctness: the header comment says clients drive per-call approval from
these hints. A read that presents as an open-world write asks for approval
it does not need; a drop or delete that presents as non-destructive gets
approval it should have asked for.

# The proving test

From the table row: `annotate` key per entry; t/lint/23 asserts presence;
`%READ` derived – every `%TOOLS` entry carries its own annotation and the
lint fails on any entry without one.

# Fix shape

Add an `annotate => [r,d,o]` key to each tool entry, delete `%ANNOTATE`,
derive `%READ` from the `readOnly` flag, and extend t/lint/23 (which already
parses the table) to assert the key on every entry. The five-tool
disagreement disappears with the single source.
