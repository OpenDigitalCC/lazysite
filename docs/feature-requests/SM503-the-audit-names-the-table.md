---
title: "SM503: a data action's audit entry names the table"
subtitle: "The operator's trail showed data-import, data-row-save and data-table-drop rows all targeting '/' - the dispatcher's path default, which answers none of the questions a trail exists for."
brand: plain
standard-margins: true
status: shipped
status-note: "OBSERVED BY THE OPERATOR 2026-08-24 reading their own audit trail on 0.10.28: every data-* entry carried '/' in the target column, because the audit's generic target is the dispatcher-level $path and data actions carry their table in the query (migrate family) or the body (row/import family). SHIPPED 0.10.29: the audit block consults both sources for data-* actions, so the trail answers WHICH TABLE was migrated, imported into, row-edited or dropped - the same enrichment shape SM465 gave acl-set and the plugin-action entries already had ('data (status)'). t/integration/73 drives the real API against a declared table and reads the real audit line for the query-carried, body-carried and non-data control cases."
---

# The observation, verbatim shape

    24/08/2026, 11:10:55  manager  ui  data-import    /  10.2.30.177  ok
    24/08/2026, 11:09:10  manager  ui  data-row-save  /  10.2.30.177  ok

# The fix

The audit's generic target is the dispatcher `$path`, which no data action
uses. For `data-*` the block now consults `$params{table}` and then the
body's `table`, so the entry names the material object - the table.
