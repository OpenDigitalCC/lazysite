---
id: SM804
title: "SM804: a row-sourced call is a connector call, and every outcome of one is in the record"
subtitle: "From 139E-05 on 0.13.9: every row-sourced connector-call returned HTTP 500 with an HTML body, and left nothing in the connector's record. One wrong subscript caused the crash; the silence was a structural mistake of mine - the row source was resolved in the CALLER, outside the only place that writes the record."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-09 on claude/sm804-a-row-source-call-is-a-connector-call. The crash was `$d->{table}{key}` - a loaded descriptor carries its table NAME under `table`, a string, so it dereferenced a string as a hash and died, and a die in a CGI is a 500. Row resolution moved INSIDE call(), wrapped in eval, so every outcome - refusal or internal fault - is a row in the connector's record with a reason, which is what SM771 requires and what my version bypassed. t/unit/manager/164 uses a REAL descriptor and REAL rows, because the test that should have caught this mocked both and invented the shape."
---

# What the field found

Every call that would actually send a row crashed: `[500]` with an HTML error
page from a JSON action. The reporter isolated it precisely, and the isolation
is what made it a ten-minute fix:

- an ordinary payload call to a dead destination answered correctly, so the
  call path was healthy;
- `row_map` **empty** was refused cleanly, by name;
- `row_map` with **any** column crashed - whatever the destination, whether the
  key existed or not.

That boundary points at one place: the code that assembles the row, reached
only once there is a column to map.

# The crash

    my $keycol = $d->{table}{key} // 'id';    # wrong

A loaded descriptor carries its table **name** under `table` - a string. So
this dereferenced a string as a hash, died, and a die in a CGI is a 500 with an
HTML body. The key is `$d->{key}`.

**Why the test did not catch it, which is the part worth keeping.** The SM579
phase 2 test mocked `load_table` and `read_rows`, and the mock returned a shape
this module had invented rather than the one the data layer returns. It proved
the mapping logic and nothing about the integration, so it passed while the
feature could not run at all. The reporter said it exactly: *"an end-to-end
connector-call with a populated row_map appears not to be exercised, since any
such test would have failed."*

`t/unit/manager/164` mocks nothing below the connector: a real descriptor, a
real migration, real rows.

# The silence, which is the better half of the report

After five crashed calls the connector's record was **empty** - the same thing
an operator would see if nobody had called it at all.

That was structural, and mine. `/docs/connectors` states the rule: *"Every
refusal is a row in the connector's own record."* I resolved the row source in
the **callers** - the control API and the MCP twin each did it before calling
in - which put every row-source outcome outside `call()`, the only place that
writes the record. So none of them were recorded, and a crash was the least
visible outcome a connector could produce.

Resolution moved inside `call()`. Every outcome now goes through the same
`_refused` path as every other refusal, and the data read is wrapped in `eval`,
so an internal fault is a recorded refusal naming what went wrong rather than a
500 naming nothing.

The reporter asked whether a call that dies inside the engine should leave a
row, and framed it as a design question rather than only a bug. The answer is
yes, for SM771's reason: an outcome nobody can see is not manageable.

# Provenance

`inbox/2026-09-09-139E-05-row-source-call-returns-500.md`.
