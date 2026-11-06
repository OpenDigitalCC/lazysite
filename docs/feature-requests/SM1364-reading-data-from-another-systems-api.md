---
id: SM1364
title: "SM1364: reading data from another system's API"
subtitle: "Where another system already holds a fact (a business's details, its bookings), a site reads it from there instead of keeping a second copy for someone to enter twice."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: data
status-note: "Filed 2026-11-06 under SM1350. The first use is an app's integration with a partner platform; the engine part is generic."
---

# Proposed

- **A source:** a data table may name an outside source:
  - an HTTPS API reached through the existing egress controls;
  - its credentials under `lazysite/`;
  - a mapping from the source's fields to the table's columns.

  The table is then read-only in lazysite for the mapped columns, and a site edits those facts at the source.
- **Refresh:** on a schedule run by the engine's existing scheduler, plus on demand. Every refresh is logged. A failed refresh keeps the last good copy and says how old it is.
- **Writing back:** none. Data flows one way, from the source; anything that must change there is changed there. An app may add a write path as its own extension.
- **Mapping the systems:** before a source is connected, the app records which system owns each fact, so nothing is held or entered in both.
- **Feeds:** a source's rows feed wizards (SM1355), schedules (SM1356) and search data (SM1357) like any table.

# Questions for ruling

1. Should a source be a kind of data table, or a connector extension (the Odoo connector's pattern)?
