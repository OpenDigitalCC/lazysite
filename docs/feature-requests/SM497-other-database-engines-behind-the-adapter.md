---
title: "SM497: other database engines behind the adapter"
subtitle: "DP-7 from the SM410 map, refiled as its own item so the data-plugin programme closes complete. SQLite is the shipped engine; the adapter pair (D11) is the seam."
brand: plain
standard-margins: true
status: parked
status-note: "REFILED 2026-08-24 from the SM410/SM447 data-plugin map at the release manager's direction: DP-1..6 + DP-8 went out in 0.10.26, the manager (DM) in 0.10.27, and DP-7 was the one map item left - gated on a decision nobody has asked for, so it becomes its own filing and the programme closes. WHAT IT IS: every SQL string lives behind the adapter pair (decision D11), currently one implementation - Lazysite::Data::SQLite (drop_table_sql, unique_index_sql, duplicate_value_sql, null_count_sql, column_values_sql, key_list_sql, and the rest). A second engine (PostgreSQL or MySQL) is a second adapter, not a rewrite. WHY PARKED: the scan-diagnosis decision already answers the scale question the way the operator ruled - 'if a user has many rows and it is slowing, they should choose a different database' - so this item is the door that ruling points at, and it opens when a real site hits the wall: sustained scan diagnostics on a real workload, or a deployment that already runs a database server and wants the store in it. NOT before: a second adapter with zero consumers is untested code wearing a test suite. WHEN OPENED: the adapter contract test (drive both adapters through the same behavioural suite) is the first artefact, not the last."
---

# What this is

DP-7 from the SM410 data-plugin map: support a second database engine behind
the D11 adapter seam. Refiled as its own item so the map reads complete
rather than carrying one permanently-gated row.

# The seam that makes it tractable

Decision D11: SQL lives behind the adapter pair, nowhere else. The shipped
engine is `Lazysite::Data::SQLite`; Schema/Tables/Query never compose SQL
strings themselves. A second engine is one new module implementing the same
methods, plus the wiring to choose it per site.

# The trigger for un-parking

- A real site's scan diagnostics (SM-scan-diagnosis: allow and diagnose,
  never refuse) show sustained slow bindings at a row count SQLite handles
  poorly, or
- a deployment that already operates a database server asks to keep the
  store in it.

The operator's ruling stands: "if a user has many rows and it is slowing,
they should choose a different database" - this filing is the door that
ruling points at.

# First artefact when opened

A behavioural adapter-contract suite that both adapters must pass unchanged
(fixtures driven by the real writer, per the standing fixture rule). Then
the second adapter against it.
