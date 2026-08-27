---
title: "SM505: a row action's audit entry names the row"
subtitle: "SM503 made the trail say which table - 'someone edited sm503' is still half an answer when the question an audit trail gets asked is which row."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-24 while building the SM503 before/after retest: one save is one row, the key is known at the point the entry is written, and a trail that names only the table answers half the question. SHIPPED 0.10.30: data-row-save and data-row-delete entries carry row=<key> in the audit detail field, read from the handler's result - the authoritative key, so an ADD names the row it created (insert returns the assigned key, auto-key tables included). ROW KEYS LAND IN THE AUDIT LOG - the release manager's decision, the SM465 trade accepted again: a key is a content identifier, and an entry that says only 'a row changed' leaves an auditor unable to tell WHICH. t/integration/73 asserts add, body-only edit and body-only delete all name the row on the real API and the real audit line."
---

# The question

SM503 (0.10.29) made every `data-*` audit entry name its table. The site
agent, building the retest, asked the follow-on: should `data-row-save`
also identify the row? One save is one row, the key is known when the
entry is written, and "which row was edited" is what a trail is for.

# The decision

Yes, for both row actions - `data-row-save` and `data-row-delete`. The
entry's detail field carries `row=<key>`, taken from the handler's result
rather than the request, because the result is authoritative: an insert
returns the assigned key, so an ADD names the row it created even on an
auto-key table.

The trade is SM465's, accepted again and recorded: row keys land in the
audit log, which may carry different retention from the data store. The
alternative - an entry that says only that a row changed - leaves an
auditor unable to tell which, and that is the whole question.

# The shape

    2026-08-24T14:01:07Z | op | data-row-save | events | 127.0.0.1 | ok | api | row=y

Table in the target column (SM503), row in the detail column (SM505).
Failure entries keep their failure reason in detail - the row key is
recorded on success only.
