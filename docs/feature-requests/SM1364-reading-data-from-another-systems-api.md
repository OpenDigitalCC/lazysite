---
id: SM1364
title: "SM1364: reading data from another system's API"
subtitle: "Where another system already holds a fact (a business's details, its bookings), a site reads it from there instead of keeping a second copy for someone to enter twice."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: data
status-note: "SHIPPED (PENDING, 0.16.9) on n783: a table names a GET source connector, its schedule entry and a map; the refresh writes through import_rows; mapped columns are read-only at every door; age from schedule-runs.json. Ruled a kind of table, not an extension. Writing back stays SM1376."
---

# Proposed

- **A source:** a data table may name an outside source:
  - an HTTPS API reached through the existing egress controls;
  - its credentials under `lazysite/`;
  - a mapping from the source's fields to the table's columns.

  The table is then read-only in lazysite for the mapped columns, and a site edits those facts at the source.
- **Refresh:** on a schedule run by the engine's existing scheduler, plus on demand. Every refresh is logged. A failed refresh keeps the last good copy and says how old it is.
- **Writing back:** see [[SM1376]] (ruling 129), which supersedes the "none" this line said: a form posts to the source's API and shows its answer, an edit to a sourced column is sent to the source, and a failed post is reported with nothing kept locally in its place.
- **Mapping the systems:** before a source is connected, the app records which system owns each fact, so nothing is held or entered in both.
- **Feeds:** a source's rows feed wizards (SM1355), schedules (SM1356) and search data (SM1357) like any table.

# Questions for ruling

1. Should a source be a kind of data table, or a connector extension (the Odoo connector's pattern)?
   **Ruled: a kind of table over a GET connector** (the accepted simple design for 0.16.9).

# Shipped

PENDING, 0.16.9, on branch n783.

- **The source:** a descriptor's `source:` names a connector (`method: GET`), the
  `schedule` entry that refreshes it, `rows` (a dotted path to the list in the answer)
  and `map` (column: field of each item). The key is mapped and is the source's own
  identifier, never the automatic `id`. Refused at save otherwise.
- **The refresh** is the existing chain: schedule entry -> connector handler -> the
  connector. Every table whose `source.connector` names the connector is refreshed
  (ruling 191: one link, no `answer_table` needed)
  through `import_rows` (`Tables::refresh_from_answer`) instead of being appended to:
  a sent row is updated in its mapped columns, a new one inserted, and a row the source
  stops sending is removed as a recorded, undoable change - only when the answer is a
  non-empty list (ruling 189). `data-table-refresh` / `refresh_data_table`
  (manage_data) make the entry's call on demand, as the caller (mode authenticated), and
  record it against the entry.
- **A failed refresh changes nothing** and is recorded (call record, event log, the
  entry's run record). The table's age is the entry's `last_ok` in schedule-runs.json,
  which a failure does not move; `data-table` shows it under `source`.
- **Mapped columns are read-only** at every door (`Tables::_write_prep`, `import_rows`),
  naming the column and the source; unmapped columns are the site's own.
- **Credentials** are the connector's secret, in the existing store, read only by
  `Connectors::call`.
- **Mapping the systems** (which system owns each fact) is the descriptor's `map`:
  a mapped column is the source's, an unmapped one the site's.
- Tests: t/unit/data/110, t/unit/manager/512.
