---
id: SM1355
title: "SM1355: wizards that build and switch rows of a data table"
subtitle: "An owner builds their list of items once, one question at a time: a menu, a price list, a service list. After that, an update is switching which items are available today, not rewriting the page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: data
status-note: "SHIPPED (PENDING, 0.16.8) on n772 with ruling 156: a table's availability field, switch_row / data-row-switch, db:<table>(available); every row change recorded, with undo, kept 90 days or the table's row_history_days (ruling 170); wizards in lazysite/db/wizards, run_wizard / data-wizard-run; the manager's data page. t/unit/mcp/78, t/unit/manager/491, t/unit/data/80, 81."
---

# Proposed

- **A wizard definition:** a file naming the data table and asking one question per step. Field types: text, price, choice, several choices, yes/no. Each step is required or optional, may depend on an earlier answer, and has help text. An app ships the definitions it needs.
- **Running it:** the wizard runs in the manager, in the simple manager (SM1353) and from a connector (`run_wizard`, step by step). It creates or edits one row. A required question cannot be skipped, so required facts are always asked, never guessed.
- **Available now:** a table can declare an availability field. The simple manager then lists the rows with one switch each (available or not). A switch is one small recorded change; it needs neither a copy (SM1354) nor a wizard.
- **Rendering:** a page shows the table's available rows through a block in its layout. Unavailable rows are hidden or marked, as the layout chooses.
- **History:** row changes are recorded like page changes, and can be undone.

# Questions for ruling

1. Should switching availability skip the preview (immediate, undoable), while building or editing items goes through it?

Ruled (156): switching a row's availability is immediate and undoable (one recorded
change, no copy or preview); building or editing a row runs the wizard.

2. How long is the row history kept?

Ruled (170): 90 days by default, with a per-table setting; a deleted row's history is
cleared after the period too, and Undo is offered only within it.

# Shipped

## Availability

A descriptor may name `availability: <field>`, which must be a declared boolean field
(`Data::Descriptor`, refused by name otherwise). `describe_data_table` / `data-table`
report it.

- **The switch**: MCP `switch_row {table, key, available}`, control API
  `data-row-switch`, and the **Available** column of the manager's data page. It sets
  that one field on one row through `Manager::Data::action_data_row_save`, recorded as
  one change of op `switch`, and answers the change with its undo. A row already in the
  asked state is not written (`unchanged`). It needs only the row write the table
  already grants: `manage_data`, or `write_data` where `writable_by` names the
  caller's group (the control API asks `row_write_refusal` and passes `row_authority`,
  as for `data-row-save`); MCP is `manage_data`, as `save_data_row` is.
- **The block**: a page binds `db:<table>(available)` (`Data::Query`'s bare word, like
  `mine`): the rows whose availability field is true. The layout renders the binding as
  any list; without `(available)` every row is given with its field, and the layout
  marks the unavailable ones as it chooses. `(available)` on a table without the field
  is refused by name (`no_availability`) and renders nothing.

## Row history and undo

`Lazysite::Data::RowHistory` records each row change in the store's `_row_changes`
table (beside `_schema_history`; an identifier no declared table can take): when, who
(the surface's actor), from where (`manager`, `api`, `mcp`, `endpoint`,
`wizard:<name>`), the op (`insert`, `update`, `delete`, `switch`, `undo`) and the row
before and after. Every save and delete through `Manager::Data::action_data_row_save`
and `action_data_row_delete` is recorded, so each door is covered by one choke point.
Recording is never fatal: a change that cannot be recorded leaves the write standing
and the answer says it has no change id. Not recorded one by one: a bulk import, a
package restore and a form handler's rows, each of which has its own record.

- **List**: MCP `list_row_changes`, control API `data-row-changes` (`manage_data`;
  the table's read rule applies), the manager's **History**.
- **Undo**: MCP `undo_row_change`, control API `data-row-undo`, **Undo** in History.
  An insert is undone by deleting the row; a delete by putting the stored row back,
  key, authors and times included (`Tables::reinsert_row`, which does not re-coerce
  stored values and so stays out of lint 137's restore-only options); anything else by
  writing back the fields that differ, through `update_row` with the caller's row
  authority. Refused, writing nothing, when the row changed after that change
  (`stale-change`, with the row as the change left it and as it is) or when it was
  undone already; a personal row is put back only by its owner or an operator. The
  undo is itself a recorded change (`undoes`), and the change it undid is marked
  (`undone_by`).

### How long the history is kept (ruling 170)

A table's changes are kept 90 days (`RowHistory::$DEFAULT_KEEP_DAYS`), or the period
its descriptor sets as `row_history_days` (a positive whole number of days, at most
36500; anything else refused by name, rule `row_history_days`). `describe_data_table`
and the history listing name the period in force. A change older than its table's
period is removed, a deleted row's changes included, the delete among them.

- **Where it runs**: on the write path only. After each recorded change (a save, a
  delete, a switch, a wizard's save, an undo) `Manager::Data::_prune_row_history`
  calls `RowHistory::prune`, which removes, per table the history names, the changes
  past that table's period (a table no longer declared is held to the default). A read
  removes nothing. The daemon has no data housekeeping job (its built-in jobs are the
  heartbeat, stats, sessions, connectors, schedule and notify outbox), so there is no
  second place; a store nobody writes to keeps its last changes until the next write.
  A failed prune is logged and the write stands.
- **Undo only inside the period**: a change still listed past it (no write yet) is
  listed with `undoable: false`, the manager shows no Undo for it, and
  `undo_row_change` / `data-row-undo` refuse it as `expired-change` (409), writing
  nothing.

## Wizards

A wizard is `lazysite/db/wizards/<name>.yaml` (inside the data extension's declared
storage, `lazysite/db/`, so it travels with the tables): `title`, `table`, and `steps`,
each with `field`, `ask`, `type` (`text`, `price`, `choice`, `choices`, `yesno`) and
optionally `required`, `help`, `options` and `when: {field, is}`.
`Lazysite::Data::Wizard::check_definition` checks it against its table: the field is
declared and of a type the step can write (price writes a decimal, choice an enum or a
text field with options, choices a text field with options stored comma-separated,
yesno a boolean); a `when` names an earlier step; the store's own key is never asked;
and a field the table requires is asked by a required step with no `when`, so required
facts are always asked, never guessed.

- **Defining**: MCP `save_wizard`, control API `data-wizard-save` (`manage_data`),
  stored as written once it loads. `list_wizards` / `data-wizards` and `data-wizard`
  read them.
- **Running**: MCP `run_wizard`, control API `data-wizard-run`, and the manager's
  wizard buttons (a new row) and **Ask** on a row (an edit). Stateless: the answers so
  far in, the next question (with its help, options and, on an edit, the row's current
  value) or `complete` with the row out. A required question answered empty is refused
  and asked again; an optional one is skipped. With `save` the row is written through
  `action_data_row_save`, recorded as from `wizard:<name>`, with the same gates as a
  row save.

## What SM1353 will reuse

The simple manager (0.17.0) needs no new engine verb for this: its row list with one
switch each is `data-rows` plus `data-row-switch`; its "undo" is `data-row-changes`
plus `data-row-undo`; its "add an item" and "change an item" are `data-wizards` plus
`data-wizard-run`, step by step, which already refuses a skipped required question.
The manager's data page (`starter/manager/data.md`: `switchRow`, `loadRowChanges`,
`undoRowChange`, `startWizard`, `wizardStep`) is the reference client for each.

## Tests

t/unit/mcp/78 (availability declared and refused; a wizard checked before it is
stored; one question at a time; a required question cannot be skipped; `when`; an
edit offering the current value; a switch as one recorded change; the page binding
hides or marks; undo, refused when stale and when done; a delete undone; no switch on
a table without the field), t/unit/manager/491 (the manager and control-API doors; a
write_data token switches only where `writable_by` names its group; the history names
the door and the account; a wizard over the API; a deleted row back with its authors;
the history and wizard definitions are `manage_data`'s), t/unit/data/80 (the
definition rules, the step walk, `(available)` refused without the field),
t/unit/data/81 (ruling 170: a bad `row_history_days` refused by name; a change past
the period listed without Undo, refused as `expired-change`, kept by a read and pruned
by the next write; a table's period overriding the default; a deleted row's history
pruned after the period). Each fails with its part reverted.
