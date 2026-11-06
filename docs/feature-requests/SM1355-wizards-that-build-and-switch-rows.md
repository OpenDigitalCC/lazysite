---
id: SM1355
title: "SM1355: wizards that build and switch rows of a data table"
subtitle: "An owner builds their list of items once, one question at a time: a menu, a price list, a service list. After that, an update is switching which items are available today, not rewriting the page."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: data
status-note: "Filed 2026-11-06 under SM1350. Builds on the existing data tables."
---

# Proposed

- **A wizard definition:** a file naming the data table and asking one question per step. Field types: text, price, choice, several choices, yes/no. Each step is required or optional, may depend on an earlier answer, and has help text. An app ships the definitions it needs.
- **Running it:** the wizard runs in the manager, in the simple manager (SM1353) and from a connector (`run_wizard`, step by step). It creates or edits one row. A required question cannot be skipped, so required facts are always asked, never guessed.
- **Available now:** a table can declare an availability field. The simple manager then lists the rows with one switch each (available or not). A switch is one small recorded change; it needs neither a copy (SM1354) nor a wizard.
- **Rendering:** a page shows the table's available rows through a block in its layout. Unavailable rows are hidden or marked, as the layout chooses.
- **History:** row changes are recorded like page changes, and can be undone.

# Questions for ruling

1. Should switching availability skip the preview (immediate, undoable), while building or editing items goes through it?
