---
title: "SM569: a form can deliver its submissions into a data table"
subtitle: "The forms plugin writes a JSONL store and mails; the data plugin holds typed, declared, exportable, bindable tables. A form that could target a table would give every submission the data manager for free."
brand: plain
standard-margins: true
status: candidate
status-note: "REQUESTED BY THE OPERATOR 2026-08-25: the form plugin should also offer a data table as an output. Shape to design when picked: a form handler of type `table` (beside `file` and `smtp`) naming a declared table; each accepted submission becomes a row through the same coercion as a live write (Value.pm), refused rows recorded like a rejected import; the spam gates, dwell/HMAC window and quarantine (SM216) stay in front of it; the manager's data page, CSV/JSON export, db: bindings and the SM512/SM514 safety exports then apply to submissions unchanged. Questions for the design: which submission meta (_id, timestamp, quarantine flag) become columns; whether the JSONL store is still written alongside (audit and SM187 bulk delete depend on it today); read_submissions vs manage_data as the governing capability for a table that holds personal data. NOT scheduled; joins the queue after the 0.10.33 plan."
---

# The request

A form target of kind `table`: submissions land as rows in a declared
data table, and everything the data plugin already gives a table -
manager, exports, bindings, safety exports - applies to them.

# The proving test

t/integration: a form bound to a `table` handler, one accepted submission
over the real handler, one row visible through data-rows and on a page
through a db: binding; a refused submission leaves no row.
